-- Contract fixes for the remaining integration failures:
--
--   1. _raw_remove_fifo (9-arg) must also expose `total_cost` (equal to `cogs`);
--      produce_inventory_unit and _deduct_sale_inventory_with_modifiers_core both
--      accumulate on `->>'total_cost'` and currently get NULL -> produced unit cost 0.
--   2. _raw_remove_fifo (9-arg) FIFO loop must accept legacy batches whose
--      warehouse_id is NULL (direct-seeded raw stock) as belonging to the resolved
--      warehouse, otherwise production reports a false shortage.
--   3. get_pos_product_availability must derive sellable stock for products sold via
--      product_unit_links -> inventory_unit_recipes (raw-material potential + ready
--      manufactured units), matching the recipes-based branch.
--   4. check_product_availability must recognize unit-linked products the same way:
--      success when raw ingredients cover the quantity, INSUFFICIENT_RAW_MATERIAL_STOCK
--      otherwise (instead of a generic INSUFFICIENT_STOCK because there is no `recipes`
--      row).
--   5. process_purchase calls the 6-arg _post_journal_entry (drop trailing auth.uid()).
--   6. receive_purchase_order posts the full-order purchase journal once the order is
--      fully received (partial receipts keep their own normalized stock, the journal is
--      posted on completion).

-- =============================================================================
-- 1/2. _raw_remove_fifo (9-arg): total_cost alias + legacy NULL-warehouse batches
-- =============================================================================
CREATE OR REPLACE FUNCTION public._raw_remove_fifo(
  p_raw_material_id uuid,
  p_branch_id uuid,
  p_quantity numeric,
  p_movement_type text,
  p_reference_type text,
  p_reference_id uuid,
  p_reference_number text,
  p_created_by uuid DEFAULT NULL::uuid,
  p_warehouse_id uuid DEFAULT NULL::uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_remaining numeric(14,4) := COALESCE(p_quantity, 0);
  v_warehouse_id uuid := p_warehouse_id;
  v_batch RECORD;
  v_take numeric(14,4);
  v_total_cost numeric(14,4) := 0;
  v_cur_qty numeric(14,4) := 0;
  v_cur_avg numeric(14,4) := 0;
  v_new_qty numeric(14,4);
  v_shortage numeric(14,4) := 0;
BEGIN
  IF v_remaining <= 0 THEN
    RETURN jsonb_build_object('success', true, 'deducted', 0, 'cogs', 0, 'total_cost', 0, 'shortage', 0);
  END IF;

  -- Resolve warehouse if missing
  IF v_warehouse_id IS NULL THEN
    SELECT id INTO v_warehouse_id
    FROM public.warehouses
    WHERE branch_id = p_branch_id AND is_active = true
    ORDER BY is_default DESC, created_at ASC
    LIMIT 1;
  END IF;

  IF v_warehouse_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_REQUIRED', 'detail', 'No active warehouse found for branch');
  END IF;

  -- Strictly verify warehouse belongs to branch!
  IF NOT EXISTS (
    SELECT 1 FROM public.warehouses
    WHERE id = v_warehouse_id AND branch_id = p_branch_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'WAREHOUSE_BRANCH_MISMATCH',
      'detail', 'Warehouse does not belong to the specified branch'
    );
  END IF;

  -- Lock balance row for this specific warehouse
  SELECT quantity, avg_cost INTO v_cur_qty, v_cur_avg
  FROM public.raw_material_inventory
  WHERE raw_material_id = p_raw_material_id
    AND branch_id = p_branch_id
    AND warehouse_id = v_warehouse_id
  FOR UPDATE;

  IF NOT FOUND THEN
    v_cur_qty := 0;
  END IF;

  IF v_cur_qty < v_remaining THEN
    v_shortage := v_remaining - v_cur_qty;
  END IF;

  -- FIFO deduction from raw_material_batches.
  -- Legacy batches seeded without a warehouse_id are treated as belonging to the
  -- resolved warehouse (single-default-warehouse compatibility).
  FOR v_batch IN
    SELECT id, quantity, unit_cost
    FROM public.raw_material_batches
    WHERE raw_material_id = p_raw_material_id
      AND branch_id = p_branch_id
      AND (warehouse_id = v_warehouse_id OR warehouse_id IS NULL)
      AND quantity > 0
    ORDER BY created_at ASC, id ASC
    FOR UPDATE
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_take := LEAST(v_remaining, v_batch.quantity);
    v_total_cost := v_total_cost + (v_take * v_batch.unit_cost);
    v_remaining := v_remaining - v_take;

    UPDATE public.raw_material_batches
    SET quantity = quantity - v_take
    WHERE id = v_batch.id;
  END LOOP;

  v_new_qty := GREATEST(0, v_cur_qty - (p_quantity - v_remaining));

  UPDATE public.raw_material_inventory
  SET quantity = v_new_qty,
      updated_at = now()
  WHERE raw_material_id = p_raw_material_id
    AND branch_id = p_branch_id
    AND warehouse_id = v_warehouse_id;

  -- Record movement (live raw_material_movements columns only)
  INSERT INTO public.raw_material_movements (
    material_id, warehouse_id, movement_type,
    quantity, reference_id, notes, branch_id, created_at
  ) VALUES (
    p_raw_material_id, v_warehouse_id, p_movement_type,
    -(p_quantity - v_remaining), p_reference_id, p_reference_number, p_branch_id, now()
  );

  RETURN jsonb_build_object(
    'success', v_remaining = 0,
    'warehouse_id', v_warehouse_id,
    'deducted', p_quantity - v_remaining,
    'cogs', ROUND(v_total_cost, 2),
    'total_cost', ROUND(v_total_cost, 2),
    'shortage', v_remaining
  );
END;
$function$;

-- =============================================================================
-- 3. get_pos_product_availability: derive stock for unit-linked products
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_pos_product_availability(p_branch_id uuid, p_warehouse_id uuid, p_cap integer DEFAULT 100000)
 RETURNS TABLE(product_id uuid, available_quantity numeric, is_available boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET "plpgsql.variable_conflict" TO 'use_column'
AS $function$
DECLARE
  v_prod RECORD;
  v_ready numeric(14,4);
  v_recipe RECORD;
  v_producible numeric(14,4);
  v_item RECORD;
  v_total numeric(14,4);
  v_link RECORD;
  v_unit_ready numeric(14,4);
  v_min_units numeric(14,4);
  v_ur RECORD;
  v_ur_need numeric(14,4);
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.user_may_access_branch(p_branch_id) THEN
    RAISE EXCEPTION 'BRANCH_ACCESS_DENIED';
  END IF;

  IF p_cap IS NULL OR p_cap < 1 THEN
    p_cap := 1;
  END IF;

  FOR v_prod IN
    SELECT p.id
    FROM public.products p
    WHERE p.branch_id = p_branch_id AND p.is_active = true
    ORDER BY p.id
  LOOP
    -- 1. Ready finished product stock in this warehouse
    SELECT COALESCE(SUM(quantity), 0) INTO v_ready
    FROM public.inventory_batches
    WHERE product_id = v_prod.id
      AND branch_id = p_branch_id
      AND warehouse_id = p_warehouse_id
      AND quantity > 0;

    v_total := v_ready;

    -- 2. Check if product has an active recipe
    SELECT r.id, r.yield_quantity
    INTO v_recipe
    FROM public.recipes r
    WHERE r.product_id = v_prod.id
      AND r.branch_id = p_branch_id
      AND r.is_active = true
    ORDER BY r.version DESC, r.created_at DESC
    LIMIT 1;

    IF v_recipe.id IS NOT NULL AND COALESCE(v_recipe.yield_quantity, 0) > 0 THEN
      v_producible := 999999999;
      FOR v_item IN
        SELECT
          ri.raw_material_id,
          SUM(ri.quantity) AS qty_per_yield
        FROM public.recipe_items ri
        JOIN public.raw_materials rm ON rm.id = ri.raw_material_id
        WHERE ri.recipe_id = v_recipe.id AND rm.is_active = true
        GROUP BY ri.raw_material_id
      LOOP
        IF v_item.qty_per_yield > 0 THEN
          v_producible := LEAST(
            v_producible,
            FLOOR(
              (
                COALESCE((
                  SELECT rmi.quantity FROM public.raw_material_inventory rmi
                  WHERE rmi.raw_material_id = v_item.raw_material_id
                    AND rmi.branch_id = p_branch_id
                    AND rmi.warehouse_id = p_warehouse_id
                ), 0) * v_recipe.yield_quantity
              ) / v_item.qty_per_yield
            )
          );
        END IF;
      END LOOP;

      IF v_producible < 999999999 AND v_producible > 0 THEN
        v_total := v_total + v_producible;
      END IF;
    END IF;

    -- 3. Products sold via manufactured inventory units (product_unit_links)
    FOR v_link IN
      SELECT pul.unit_id, pul.quantity
      FROM public.product_unit_links pul
      JOIN public.inventory_units iu ON iu.id = pul.unit_id
      WHERE pul.product_id = v_prod.id
        AND iu.branch_id = p_branch_id
        AND iu.is_active = true
    LOOP
      -- 3a. Ready manufactured-unit stock in this warehouse
      SELECT COALESCE(SUM(iub.quantity), 0) INTO v_unit_ready
      FROM public.inventory_unit_batches iub
      WHERE iub.unit_id = v_link.unit_id
        AND iub.branch_id = p_branch_id
        AND iub.warehouse_id = p_warehouse_id
        AND iub.quantity > 0;

      IF v_unit_ready > 0 THEN
        v_total := v_total + FLOOR(v_unit_ready / v_link.quantity);
      END IF;

      -- 3b. Raw-material potential for this unit's recipe
      v_min_units := 999999999;
      FOR v_ur IN
        SELECT iur.raw_material_id, iur.quantity, COALESCE(iur.wastage_percent, 0) AS wastage_percent
        FROM public.inventory_unit_recipes iur
        WHERE iur.unit_id = v_link.unit_id
      LOOP
        v_ur_need := v_ur.quantity * (1 + v_ur.wastage_percent / 100.0);
        IF v_ur_need > 0 THEN
          v_min_units := LEAST(
            v_min_units,
            FLOOR(
              COALESCE((
                SELECT rmi.quantity FROM public.raw_material_inventory rmi
                WHERE rmi.raw_material_id = v_ur.raw_material_id
                  AND rmi.branch_id = p_branch_id
                  AND rmi.warehouse_id = p_warehouse_id
              ), 0) / v_ur_need
            )
          );
        END IF;
      END LOOP;

      IF v_min_units < 999999999 AND v_min_units > 0 THEN
        v_total := v_total + FLOOR(v_min_units / v_link.quantity);
      END IF;
    END LOOP;

    product_id := v_prod.id;
    available_quantity := LEAST(v_total, p_cap);
    is_available := v_total > 0;
    RETURN NEXT;
  END LOOP;
END;
$function$;

-- =============================================================================
-- 4. check_product_availability: recognize unit-linked products
-- =============================================================================
CREATE OR REPLACE FUNCTION public.check_product_availability(p_product_id uuid, p_branch_id uuid, p_warehouse_id uuid, p_quantity numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_product RECORD;
  v_warehouse RECORD;
  v_ready numeric(14,4) := 0;
  v_shortage numeric(14,4);
  v_recipe RECORD;
  v_item RECORD;
  v_req_qty numeric(14,4);
  v_avail_qty numeric(14,4);
  v_producible_max numeric(14,4) := 999999999;
  v_has_recipe_items boolean := false;
  v_link RECORD;
  v_ur RECORD;
  v_ur_need numeric(14,4);
  v_ur_avail numeric(14,4);
  v_unit_max numeric(14,4) := 999999999;
  v_allowed numeric(14,4) := 0;
  v_has_links boolean := false;
  v_limit_raw uuid;
  v_limit_raw_name text;
  v_limit_avail numeric(14,4) := 0;
  v_limit_need numeric(14,4) := 0;
BEGIN
  IF p_quantity <= 0 THEN
    RETURN jsonb_build_object('success', true, 'mode', 'none', 'available', 0);
  END IF;

  IF p_warehouse_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'WAREHOUSE_REQUIRED',
      'detail', 'A warehouse must be specified for availability check.'
    );
  END IF;

  SELECT id, name, is_active INTO v_product
  FROM public.products
  WHERE id = p_product_id AND branch_id = p_branch_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'PRODUCT_NOT_FOUND',
      'product_id', p_product_id
    );
  END IF;

  SELECT id, name INTO v_warehouse
  FROM public.warehouses
  WHERE id = p_warehouse_id AND branch_id = p_branch_id AND is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'WAREHOUSE_NOT_FOUND',
      'warehouse_id', p_warehouse_id
    );
  END IF;

  -- 1. Check ready stock in the specific warehouse
  SELECT COALESCE(SUM(quantity), 0) INTO v_ready
  FROM public.inventory_batches
  WHERE product_id = p_product_id
    AND branch_id = p_branch_id
    AND warehouse_id = p_warehouse_id
    AND quantity > 0;

  -- 2. If ready stock fully satisfies the requested quantity
  IF v_ready >= p_quantity THEN
    RETURN jsonb_build_object(
      'success', true,
      'mode', 'ready_product',
      'available', v_ready,
      'ready_quantity', v_ready,
      'recipe_quantity', 0,
      'warehouse_id', p_warehouse_id,
      'warehouse_name', v_warehouse.name
    );
  END IF;

  -- 3. If ready stock is insufficient, check if an active recipe exists
  SELECT r.id, r.yield_quantity, r.is_active
  INTO v_recipe
  FROM public.recipes r
  WHERE r.product_id = p_product_id
    AND r.branch_id = p_branch_id
    AND r.is_active = true
  ORDER BY r.version DESC, r.created_at DESC
  LIMIT 1;

  IF NOT FOUND OR v_recipe.id IS NULL OR COALESCE(v_recipe.yield_quantity, 0) <= 0 THEN
    -- 3b. No production recipe: products sold via manufactured inventory units.
    v_allowed := v_ready;
    FOR v_link IN
      SELECT pul.unit_id, pul.quantity
      FROM public.product_unit_links pul
      JOIN public.inventory_units iu ON iu.id = pul.unit_id
      WHERE pul.product_id = p_product_id
        AND iu.branch_id = p_branch_id
        AND iu.is_active = true
    LOOP
      v_has_links := true;
      v_unit_max := 999999999;

      -- Ready manufactured units in this warehouse count toward the sale
      SELECT COALESCE(SUM(iub.quantity), 0) INTO v_avail_qty
      FROM public.inventory_unit_batches iub
      WHERE iub.unit_id = v_link.unit_id
        AND iub.branch_id = p_branch_id
        AND iub.warehouse_id = p_warehouse_id
        AND iub.quantity > 0;
      v_allowed := v_allowed + FLOOR(v_avail_qty / v_link.quantity);

      -- Raw-material potential from this unit's recipe
      FOR v_ur IN
        SELECT iur.raw_material_id, iur.quantity, COALESCE(iur.wastage_percent, 0) AS wastage_percent
        FROM public.inventory_unit_recipes iur
        WHERE iur.unit_id = v_link.unit_id
      LOOP
        v_ur_need := v_ur.quantity * (1 + v_ur.wastage_percent / 100.0);
        IF v_ur_need > 0 THEN
          SELECT COALESCE(quantity, 0) INTO v_ur_avail
          FROM public.raw_material_inventory
          WHERE raw_material_id = v_ur.raw_material_id
            AND branch_id = p_branch_id
            AND warehouse_id = p_warehouse_id;
          v_ur_avail := COALESCE(v_ur_avail, 0);

          IF FLOOR(v_ur_avail / v_ur_need) < v_unit_max THEN
            v_unit_max := FLOOR(v_ur_avail / v_ur_need);
            v_limit_raw := v_ur.raw_material_id;
            v_limit_avail := v_ur_avail;
            v_limit_need := v_ur_need;
          END IF;
        END IF;
      END LOOP;

      IF v_unit_max < 999999999 THEN
        v_allowed := v_allowed + FLOOR(v_unit_max / v_link.quantity);
      END IF;
    END LOOP;

    IF NOT v_has_links THEN
      -- No recipe and no unit links: out of stock
      RETURN jsonb_build_object(
        'success', false,
        'error', 'INSUFFICIENT_STOCK',
        'item_type', 'product',
        'product_id', p_product_id,
        'product_name', v_product.name,
        'required', p_quantity,
        'available', v_ready,
        'shortage', p_quantity - v_ready,
        'warehouse_id', p_warehouse_id,
        'warehouse_name', v_warehouse.name,
        'detail', 'الرصيد الجاهز غير كافٍ ولا توجد وصفة إنتاج نشطة للمنتج في هذا المستودع.'
      );
    END IF;

    IF v_allowed >= p_quantity THEN
      RETURN jsonb_build_object(
        'success', true,
        'mode', CASE WHEN v_ready > 0 THEN 'hybrid' ELSE 'recipe' END,
        'available', v_allowed,
        'ready_quantity', v_ready,
        'recipe_quantity', GREATEST(p_quantity - v_ready, 0),
        'warehouse_id', p_warehouse_id,
        'warehouse_name', v_warehouse.name
      );
    END IF;

    v_limit_raw_name := (SELECT name FROM public.raw_materials WHERE id = v_limit_raw);
    RETURN jsonb_build_object(
      'success', false,
      'error', 'INSUFFICIENT_RAW_MATERIAL_STOCK',
      'item_type', 'raw_material',
      'product_id', p_product_id,
      'product_name', v_product.name,
      'raw_material_id', v_limit_raw,
      'raw_material_name', v_limit_raw_name,
      'required', v_limit_need * (p_quantity - v_allowed),
      'available', v_limit_avail,
      'shortage', GREATEST(v_limit_need * (p_quantity - v_allowed) - v_limit_avail, 0),
      'warehouse_id', p_warehouse_id,
      'warehouse_name', v_warehouse.name,
      'detail', format('الخامة (%s) غير كافية لإنتاج الوحدات المطلوبة. المطلوب: %s، المتوفر: %s',
                       COALESCE(v_limit_raw_name, ''), v_limit_need * (p_quantity - v_allowed), v_limit_avail)
    );
  END IF;

  -- Check recipe items strictly in the same warehouse
  v_shortage := p_quantity - v_ready;

  -- Check Raw Materials (grouped by raw_material_id to prevent duplicate rows)
  FOR v_item IN
    SELECT
      ri.raw_material_id,
      rm.name AS raw_name,
      SUM(ri.quantity) AS qty_per_yield
    FROM public.recipe_items ri
    JOIN public.raw_materials rm ON rm.id = ri.raw_material_id
    WHERE ri.recipe_id = v_recipe.id
      AND rm.is_active = true
    GROUP BY ri.raw_material_id, rm.name
  LOOP
    v_has_recipe_items := true;
    v_req_qty := (v_item.qty_per_yield / v_recipe.yield_quantity) * v_shortage;

    SELECT COALESCE(quantity, 0) INTO v_avail_qty
    FROM public.raw_material_inventory
    WHERE raw_material_id = v_item.raw_material_id
      AND branch_id = p_branch_id
      AND warehouse_id = p_warehouse_id;

    v_avail_qty := COALESCE(v_avail_qty, 0);

    IF v_avail_qty < v_req_qty THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'INSUFFICIENT_RAW_MATERIAL_STOCK',
        'item_type', 'raw_material',
        'product_id', p_product_id,
        'product_name', v_product.name,
        'raw_material_id', v_item.raw_material_id,
        'raw_material_name', v_item.raw_name,
        'required', v_req_qty,
        'available', v_avail_qty,
        'shortage', v_req_qty - v_avail_qty,
        'warehouse_id', p_warehouse_id,
        'warehouse_name', v_warehouse.name,
        'detail', format('الخامة (%s) غير كافية في مستودع (%s). المطلوب: %s، المتوفر: %s',
                         v_item.raw_name, v_warehouse.name, v_req_qty, v_avail_qty)
      );
    END IF;

    IF v_item.qty_per_yield > 0 THEN
      v_producible_max := LEAST(v_producible_max, FLOOR((v_avail_qty * v_recipe.yield_quantity) / v_item.qty_per_yield));
    END IF;
  END LOOP;

  IF NOT v_has_recipe_items THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'INSUFFICIENT_STOCK',
      'item_type', 'product',
      'product_id', p_product_id,
      'product_name', v_product.name,
      'required', p_quantity,
      'available', v_ready,
      'shortage', v_shortage,
      'warehouse_id', p_warehouse_id,
      'warehouse_name', v_warehouse.name,
      'detail', 'وصفة المنتج خالية من المواد الخام النشطة.'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'mode', CASE WHEN v_ready > 0 THEN 'hybrid' ELSE 'recipe' END,
    'available', v_ready + v_producible_max,
    'ready_quantity', v_ready,
    'recipe_quantity', v_shortage,
    'warehouse_id', p_warehouse_id,
    'warehouse_name', v_warehouse.name
  );
END;
$function$;

-- =============================================================================
-- 5. process_purchase: call the 6-arg _post_journal_entry
-- =============================================================================
CREATE OR REPLACE FUNCTION public.process_purchase(
  p_invoice_number text,
  p_supplier_id uuid,
  p_branch_id uuid,
  p_warehouse_id uuid,
  p_subtotal numeric,
  p_discount_amount numeric,
  p_tax_amount numeric,
  p_total numeric,
  p_paid_amount numeric,
  p_payment_method text,
  p_status text,
  p_notes text,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_purchase_id uuid;
  v_user_branch uuid;
  v_item jsonb;
  v_product_id uuid;
  v_raw_id uuid;
  v_quantity numeric(14,4);
  v_unit_cost numeric(14,4);
  v_res jsonb;
  v_goods_fg numeric(14,2) := 0;
  v_goods_rm numeric(14,2) := 0;
  v_lines jsonb := '[]'::jsonb;
  v_dr numeric(14,2) := 0;
  v_cr numeric(14,2) := 0;
  v_diff numeric(14,2);
  v_paid numeric(14,2);
  v_ap numeric(14,2);
  v_stock numeric(14,4);
  v_stock_val numeric(14,2);
  v_new_cost numeric(12,2);
  v_unit_name text;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMPTY_PURCHASE');
  END IF;

  IF p_warehouse_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'WAREHOUSE_REQUIRED',
      'detail', 'يرجى تحديد المستودع المستلم للمشتريات'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.warehouses
    WHERE id = p_warehouse_id AND branch_id = p_branch_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'WAREHOUSE_BRANCH_MISMATCH',
      'detail', 'المستودع المحدد لا ينتمي إلى فرع الفاتورة'
    );
  END IF;

  IF NOT is_pos_admin() AND get_user_role() NOT IN ('warehouse_manager','branch_manager') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;

  IF NOT is_pos_admin() THEN
    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    IF v_user_branch IS NOT NULL AND p_branch_id IS NOT NULL AND v_user_branch <> p_branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;
  END IF;

  -- Validate items
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_raw_id := (v_item->>'raw_material_id')::uuid;
    v_quantity := COALESCE((v_item->>'quantity')::numeric, 0);

    IF (v_product_id IS NULL) = (v_raw_id IS NULL) THEN
      RETURN jsonb_build_object('success', false, 'error', 'ITEM_MISSING_TYPE');
    END IF;
    IF v_quantity <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY');
    END IF;
  END LOOP;

  -- Write purchase header
  INSERT INTO public.purchases (
    invoice_number, supplier_id, branch_id, warehouse_id, buyer_id,
    subtotal, discount_amount, tax_amount, total, paid_amount,
    payment_method, status, notes
  ) VALUES (
    p_invoice_number, p_supplier_id, p_branch_id, p_warehouse_id, auth.uid(),
    p_subtotal, p_discount_amount, p_tax_amount, p_total, p_paid_amount,
    p_payment_method, p_status, p_notes
  ) RETURNING id INTO v_purchase_id;

  -- Write purchase items and credit stock to the selected warehouse
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_raw_id := (v_item->>'raw_material_id')::uuid;
    v_quantity := COALESCE((v_item->>'quantity')::numeric, 0);
    v_unit_cost := COALESCE((v_item->>'unit_cost')::numeric, 0);

    IF v_product_id IS NOT NULL THEN
      INSERT INTO public.purchase_items (
        purchase_id, product_id, unit_name, quantity, unit_cost, total
      ) VALUES (
        v_purchase_id, v_product_id, COALESCE(v_item->>'unit_name', 'piece'),
        v_quantity, v_unit_cost, v_quantity * v_unit_cost
      );

      v_res := public._product_inv_add(
        v_product_id, p_warehouse_id, p_branch_id, v_quantity,
        v_unit_cost, v_item->>'batch_number',
        (v_item->>'production_date')::date, (v_item->>'expiry_date')::date,
        'purchase', 'purchase', v_purchase_id, p_invoice_number, auth.uid()
      );
      IF NOT (v_res->>'success')::boolean THEN
        RETURN v_res;
      END IF;

      -- Update weighted-average cost
      SELECT COALESCE(SUM(b.quantity), 0), COALESCE(SUM(b.quantity * b.unit_cost), 0)
      INTO v_stock, v_stock_val
      FROM public.inventory_batches b WHERE b.product_id = v_product_id;
      v_new_cost := CASE WHEN v_stock > 0 THEN round(v_stock_val / v_stock, 2) ELSE v_unit_cost END;
      UPDATE public.products SET cost_price = v_new_cost, updated_at = now() WHERE id = v_product_id;

      v_goods_fg := round(v_goods_fg + v_quantity * v_unit_cost, 2);
    ELSE
      SELECT COALESCE(u.symbol, u.name, 'وحدة') INTO v_unit_name
      FROM public.raw_materials rm LEFT JOIN public.units u ON u.id = rm.unit_id
      WHERE rm.id = v_raw_id;

      INSERT INTO public.purchase_items (
        purchase_id, raw_material_id, unit_name, quantity, unit_cost, total
      ) VALUES (
        v_purchase_id, v_raw_id, COALESCE(NULLIF(v_item->>'unit_name', ''), v_unit_name),
        v_quantity, v_unit_cost, v_quantity * v_unit_cost
      );

      v_res := public._raw_add_in_warehouse(
        p_raw_material_id := v_raw_id,
        p_branch_id := p_branch_id,
        p_quantity := v_quantity,
        p_unit_cost := v_unit_cost,
        p_movement_type := 'purchase',
        p_reference_type := 'purchase',
        p_reference_id := v_purchase_id,
        p_reference_number := p_invoice_number,
        p_notes := v_item->>'notes',
        p_batch_number := v_item->>'batch_number',
        p_created_by := auth.uid(),
        p_warehouse_id := p_warehouse_id
      );
      IF NOT (v_res->>'success')::boolean THEN
        RETURN v_res;
      END IF;

      v_goods_rm := round(v_goods_rm + v_quantity * v_unit_cost, 2);
    END IF;
  END LOOP;

  -- Accounting Entries for completed purchases
  IF COALESCE(p_status, 'completed') = 'completed' THEN
    v_paid := round(COALESCE(p_paid_amount, 0), 2);
    v_ap := round(COALESCE(p_total, 0) - v_paid, 2);

    IF v_goods_fg > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'inventory_fg', 'debit', v_goods_fg, 'credit', 0, 'note', p_invoice_number);
      v_dr := v_dr + v_goods_fg;
    END IF;
    IF v_goods_rm > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'inventory_rm', 'debit', v_goods_rm, 'credit', 0, 'note', p_invoice_number);
      v_dr := v_dr + v_goods_rm;
    END IF;
    IF COALESCE(p_tax_amount, 0) > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'vat_input', 'debit', p_tax_amount, 'credit', 0, 'note', p_invoice_number);
      v_dr := v_dr + p_tax_amount;
    END IF;
    IF v_paid > 0 THEN
      v_lines := v_lines || jsonb_build_object(
        'account_key', CASE WHEN p_payment_method IN ('card','bank') THEN 'bank' ELSE 'cash' END,
        'debit', 0, 'credit', v_paid, 'note', p_invoice_number
      );
      v_cr := v_cr + v_paid;
    END IF;
    IF v_ap > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'accounts_payable', 'debit', 0, 'credit', v_ap, 'note', p_invoice_number);
      v_cr := v_cr + v_ap;
    END IF;

    v_diff := round(v_dr - v_cr, 2);
    IF abs(v_diff) > 0 AND abs(v_diff) <= 0.05 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'cogs', 'debit', CASE WHEN v_diff < 0 THEN abs(v_diff) ELSE 0 END, 'credit', CASE WHEN v_diff > 0 THEN v_diff ELSE 0 END, 'note', 'Rounding diff');
    END IF;

    IF jsonb_array_length(v_lines) > 0 THEN
      PERFORM public._post_journal_entry(p_branch_id, 'purchase', v_purchase_id, p_invoice_number,
        'فاتورة مشتريات ' || p_invoice_number, v_lines);
    END IF;
  END IF;

  RETURN jsonb_build_object('success', true, 'purchase_id', v_purchase_id);
END;
$$;

-- =============================================================================
-- 6. receive_purchase_order: post the full-order journal on completion
-- =============================================================================
CREATE OR REPLACE FUNCTION public.receive_purchase_order(
  p_purchase_id uuid,
  p_receipt_items jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', pg_temp
AS $function$
DECLARE
  v_purchase record;
  v_user_branch uuid;
  v_receipt_id uuid;
  v_number text;
  v_item jsonb;
  v_pitem record;
  v_qty numeric(14,4);
  v_res jsonb;
  v_stock numeric(14,4);
  v_stock_val numeric(14,2);
  v_new_cost numeric(12,2);
  v_fully_received boolean := true;
  v_rows integer := 0;
  v_goods_fg numeric(14,2) := 0;
  v_goods_rm numeric(14,2) := 0;
  v_lines jsonb := '[]'::jsonb;
  v_dr numeric(14,2) := 0;
  v_cr numeric(14,2) := 0;
  v_diff numeric(14,2);
  v_paid numeric(14,2);
  v_ap numeric(14,2);
  v_tax numeric(14,2);
BEGIN
  IF p_receipt_items IS NULL OR jsonb_array_length(p_receipt_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMPTY_RECEIPT');
  END IF;

  IF NOT is_pos_admin() AND NOT can_permission('purchases.manage') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;

  SELECT * INTO v_purchase FROM public.purchases WHERE id = p_purchase_id FOR UPDATE;
  IF v_purchase.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FOUND');
  END IF;

  IF v_purchase.warehouse_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'WAREHOUSE_REQUIRED', 'detail', 'المستودع غير محدد في أمر الشراء');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.warehouses
    WHERE id = v_purchase.warehouse_id AND branch_id = v_purchase.branch_id
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'WAREHOUSE_BRANCH_MISMATCH',
      'detail', 'مستودع الاستلام لا ينتمي إلى فرع أمر الشراء'
    );
  END IF;

  IF v_purchase.status NOT IN ('approved', 'submitted', 'partial') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_RECEIVABLE', 'status', v_purchase.status);
  END IF;

  IF NOT is_pos_admin() THEN
    SELECT branch_id INTO v_user_branch FROM public.users WHERE id = auth.uid();
    IF v_user_branch IS NOT NULL AND v_user_branch <> v_purchase.branch_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
    END IF;
  END IF;

  -- Validate lines
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_receipt_items)
  LOOP
    v_qty := COALESCE((v_item->>'quantity_received')::numeric, 0);
    IF v_qty <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY');
    END IF;
    SELECT * INTO v_pitem FROM public.purchase_items
    WHERE id = (v_item->>'purchase_item_id')::uuid;
    IF v_pitem.id IS NULL OR v_purchase.id <> v_pitem.purchase_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_ITEM_NOT_FOUND');
    END IF;
    IF v_qty > v_pitem.quantity - COALESCE(v_pitem.received_quantity, 0) THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'OVER_RECEIPT',
        'purchase_item_id', v_item->>'purchase_item_id',
        'ordered', v_pitem.quantity,
        'already_received', v_pitem.received_quantity,
        'receiving', v_qty
      );
    END IF;
  END LOOP;

  v_number := (public.next_document_number('purchase_receipt')->>'number')::text;

  INSERT INTO public.purchase_receipts (
    receipt_number, purchase_id, branch_id, warehouse_id, received_by, notes
  ) VALUES (
    v_number, p_purchase_id, v_purchase.branch_id, v_purchase.warehouse_id, auth.uid(), NULL
  ) RETURNING id INTO v_receipt_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_receipt_items)
  LOOP
    v_qty := COALESCE((v_item->>'quantity_received')::numeric, 0);
    SELECT * INTO v_pitem FROM public.purchase_items WHERE id = (v_item->>'purchase_item_id')::uuid;

    INSERT INTO public.purchase_receipt_items (receipt_id, purchase_item_id, quantity_received, unit_cost)
    VALUES (v_receipt_id, v_pitem.id, v_qty, v_pitem.unit_cost);

    IF v_pitem.product_id IS NOT NULL THEN
      v_res := public._product_inv_add(
        v_pitem.product_id, v_purchase.warehouse_id, v_purchase.branch_id,
        v_qty, v_pitem.unit_cost, NULL, NULL, NULL,
        'purchase', 'purchase', p_purchase_id, v_purchase.invoice_number, auth.uid()
      );
      IF NOT (v_res->>'success')::boolean THEN
        RETURN v_res;
      END IF;

      SELECT COALESCE(SUM(b.quantity), 0), COALESCE(SUM(b.quantity * b.unit_cost), 0)
      INTO v_stock, v_stock_val
      FROM public.inventory_batches b WHERE b.product_id = v_pitem.product_id;
      v_new_cost := CASE WHEN v_stock > 0 THEN round(v_stock_val / v_stock, 2) ELSE v_pitem.unit_cost END;
      UPDATE public.products SET cost_price = v_new_cost, updated_at = now() WHERE id = v_pitem.product_id;

      v_goods_fg := round(v_goods_fg + v_qty * v_pitem.unit_cost, 2);
    ELSE
      v_res := public._raw_add_in_warehouse(
        p_raw_material_id := v_pitem.raw_material_id,
        p_branch_id := v_purchase.branch_id,
        p_quantity := v_qty,
        p_unit_cost := v_pitem.unit_cost,
        p_movement_type := 'purchase',
        p_reference_type := 'purchase_receipt',
        p_reference_id := p_purchase_id,
        p_reference_number := v_purchase.invoice_number,
        p_created_by := auth.uid(),
        p_warehouse_id := v_purchase.warehouse_id
      );
      IF NOT (v_res->>'success')::boolean THEN
        RETURN v_res;
      END IF;

      v_goods_rm := round(v_goods_rm + v_qty * v_pitem.unit_cost, 2);
    END IF;

    UPDATE public.purchase_items
    SET received_quantity = COALESCE(received_quantity, 0) + v_qty
    WHERE id = v_pitem.id;

    v_rows := v_rows + 1;
  END LOOP;

  SELECT EXISTS (
    SELECT 1 FROM public.purchase_items
    WHERE purchase_id = p_purchase_id
      AND quantity - COALESCE(received_quantity, 0) > 0
  ) INTO v_fully_received;
  v_fully_received := NOT v_fully_received;

  IF v_fully_received THEN
    -- Post the full-order purchase journal once the order is fully received.
    SELECT COALESCE(SUM(CASE WHEN product_id IS NOT NULL THEN quantity * unit_cost END), 0),
           COALESCE(SUM(CASE WHEN raw_material_id IS NOT NULL THEN quantity * unit_cost END), 0)
    INTO v_goods_fg, v_goods_rm
    FROM public.purchase_items
    WHERE purchase_id = p_purchase_id;

    v_paid := round(COALESCE(v_purchase.paid_amount, 0), 2);
    v_ap := round(COALESCE(v_purchase.total, 0) - v_paid, 2);
    v_dr := 0;
    v_cr := 0;
    v_lines := '[]'::jsonb;

    IF v_goods_fg > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'inventory_fg', 'debit', v_goods_fg, 'credit', 0, 'note', COALESCE(v_purchase.invoice_number, v_number));
      v_dr := v_dr + v_goods_fg;
    END IF;
    IF v_goods_rm > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'inventory_rm', 'debit', v_goods_rm, 'credit', 0, 'note', COALESCE(v_purchase.invoice_number, v_number));
      v_dr := v_dr + v_goods_rm;
    END IF;
    IF COALESCE(v_purchase.tax_amount, 0) > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'vat_input', 'debit', COALESCE(v_purchase.tax_amount, 0), 'credit', 0, 'note', COALESCE(v_purchase.invoice_number, v_number));
      v_dr := v_dr + COALESCE(v_purchase.tax_amount, 0);
    END IF;
    IF v_paid > 0 THEN
      v_lines := v_lines || jsonb_build_object(
        'account_key', CASE WHEN v_purchase.payment_method IN ('card','bank') THEN 'bank' ELSE 'cash' END,
        'debit', 0, 'credit', v_paid, 'note', COALESCE(v_purchase.invoice_number, v_number)
      );
      v_cr := v_cr + v_paid;
    END IF;
    IF v_ap > 0 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'accounts_payable', 'debit', 0, 'credit', v_ap, 'note', COALESCE(v_purchase.invoice_number, v_number));
      v_cr := v_cr + v_ap;
    END IF;

    v_diff := round(v_dr - v_cr, 2);
    IF abs(v_diff) > 0 AND abs(v_diff) <= 0.05 THEN
      v_lines := v_lines || jsonb_build_object('account_key', 'cogs', 'debit', CASE WHEN v_diff < 0 THEN abs(v_diff) ELSE 0 END, 'credit', CASE WHEN v_diff > 0 THEN v_diff ELSE 0 END, 'note', 'Rounding diff');
    END IF;

    IF jsonb_array_length(v_lines) > 0 THEN
      PERFORM public._post_journal_entry(
        v_purchase.branch_id, 'purchase', p_purchase_id,
        COALESCE(v_purchase.invoice_number, v_number),
        'استلام أمر شراء ' || v_number, v_lines
      );
    END IF;
  END IF;

  UPDATE public.purchases
  SET status = CASE WHEN v_fully_received THEN 'received' ELSE 'partial' END,
      updated_at = now()
  WHERE id = p_purchase_id;

  RETURN jsonb_build_object(
    'success', true,
    'receipt_id', v_receipt_id,
    'receipt_number', v_number,
    'fully_received', v_fully_received
  );
END;
$function$;