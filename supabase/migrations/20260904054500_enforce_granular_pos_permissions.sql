-- Complete the permission-first POS contract without revoking existing access.
-- Legacy permissions remain available for old screens, while current role rows
-- receive equivalent granular capabilities before enforcement switches over.

UPDATE public.roles
SET permissions = permissions
  || CASE WHEN permissions ? 'pos.sell' THEN '["pos.view","pos.order.create","pos.order.edit"]'::jsonb ELSE '[]'::jsonb END
  || CASE WHEN permissions ? 'pos.pay' THEN '["pos.payment.take","pos.receipt.print"]'::jsonb ELSE '[]'::jsonb END
  || CASE WHEN permissions ? 'pos.split_order' THEN '["pos.order.split"]'::jsonb ELSE '[]'::jsonb END
  || CASE WHEN permissions ? 'pos.transfer_order' THEN '["pos.order.transfer"]'::jsonb ELSE '[]'::jsonb END
  || CASE WHEN permissions ? 'sales.print' OR permissions ? 'pos.reprint' THEN '["pos.receipt.print"]'::jsonb ELSE '[]'::jsonb END,
    updated_at = now()
WHERE permissions ?| ARRAY['pos.sell','pos.pay','pos.split_order','pos.transfer_order','sales.print','pos.reprint'];

-- De-duplicate role permission arrays after the compatibility expansion.
UPDATE public.roles r
SET permissions = (
  SELECT jsonb_agg(value ORDER BY value)
  FROM (SELECT DISTINCT value FROM jsonb_array_elements_text(r.permissions)) p
), updated_at = now();

CREATE OR REPLACE FUNCTION public.enforce_pos_permission_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_is_service_role boolean := COALESCE(current_setting('role', true), '') = 'service_role';
BEGIN
  IF v_is_service_role OR v_uid IS NULL THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'sales' THEN
    IF TG_OP = 'INSERT' AND NOT public.can_permission('pos.payment.take') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.payment.take';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'order_kitchen_sends' THEN
    IF NOT public.can_permission('pos.send_kitchen') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.send_kitchen';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'orders' THEN
    IF TG_OP = 'INSERT' THEN
      IF NOT public.can_permission('pos.order.create') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.order.create';
      END IF;
      RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
      IF NOT public.can_permission('pos.cancel_order') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.cancel_order';
      END IF;
      RETURN OLD;
    END IF;

    IF NEW.kitchen_status IS DISTINCT FROM OLD.kitchen_status
       AND (to_jsonb(NEW) - ARRAY['kitchen_status','kitchen_sent_at','kitchen_ready_at','updated_at']::text[])
         = (to_jsonb(OLD) - ARRAY['kitchen_status','kitchen_sent_at','kitchen_ready_at','updated_at']::text[]) THEN
      IF OLD.kitchen_status = 'pending'
         AND NEW.kitchen_status = 'sent'
         AND public.can_permission('pos.send_kitchen')
         AND EXISTS (SELECT 1 FROM public.order_kitchen_sends s WHERE s.order_id = OLD.id) THEN
        RETURN NEW;
      END IF;
      IF NOT public.can_permission('pos.kds_view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.kds_view';
      END IF;
      RETURN NEW;
    END IF;

    IF NEW.station IS DISTINCT FROM OLD.station
       AND (to_jsonb(NEW) - ARRAY['station','updated_at']::text[])
         = (to_jsonb(OLD) - ARRAY['station','updated_at']::text[]) THEN
      IF NOT public.can_permission('pos.kds_view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.kds_view';
      END IF;
      RETURN NEW;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
      IF NEW.status = 'cancelled' AND NOT public.can_permission('pos.cancel_order') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.cancel_order';
      ELSIF NEW.status = 'completed' THEN
        IF NOT public.can_permission('pos.payment.take') THEN
          RAISE EXCEPTION 'PERMISSION_DENIED:pos.payment.take';
        END IF;
        IF NOT public.can_permission('pos.order.edit')
           AND (to_jsonb(NEW)-ARRAY['status','payment_status','payment_at','updated_at']::text[])
             IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','payment_status','payment_at','updated_at']::text[]) THEN
          RAISE EXCEPTION 'PERMISSION_DENIED:pos.order.edit';
        END IF;
      ELSIF NEW.status IN ('open', 'held') AND NOT public.can_permission('pos.hold') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.hold';
      END IF;
    END IF;

    IF NEW.table_id IS DISTINCT FROM OLD.table_id
       AND OLD.table_id IS NOT NULL
       AND NOT public.can_permission('pos.order.transfer') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.order.transfer';
    END IF;

    IF NEW.status IS NOT DISTINCT FROM OLD.status
       AND NEW.table_id IS NOT DISTINCT FROM OLD.table_id
       AND NOT public.can_permission('pos.order.edit') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.order.edit';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'order_items' THEN
    IF TG_OP = 'INSERT' THEN
      IF NOT public.can_permission('pos.order.create')
         AND NOT public.can_permission('pos.order.edit') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.order.edit';
      END IF;
      RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
      IF NOT public.can_permission('pos.void') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.void';
      END IF;
      RETURN OLD;
    END IF;

    IF NEW.order_id IS DISTINCT FROM OLD.order_id THEN
      IF NOT public.can_permission('pos.order.split') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED:pos.order.split';
      END IF;
    ELSIF NOT public.can_permission('pos.order.edit') THEN
      RAISE EXCEPTION 'PERMISSION_DENIED:pos.order.edit';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_pos_permission_mutation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_pos_permission_mutation() TO service_role;

CREATE OR REPLACE FUNCTION public.authorize_sale_print(p_sale_id uuid,p_approval_request_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_sale public.sales%ROWTYPE; v_user public.users%ROWTYPE; v_count integer; v_req public.approval_requests%ROWTYPE; v_event_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success',false,'error','AUTH_REQUIRED'); END IF;
  SELECT * INTO v_user FROM public.users WHERE id=auth.uid() AND is_active=true;
  SELECT * INTO v_sale FROM public.sales WHERE id=p_sale_id;
  IF v_sale.id IS NULL THEN RETURN jsonb_build_object('success',false,'error','SALE_NOT_FOUND'); END IF;
  IF NOT public.user_may_access_branch(v_sale.branch_id) THEN RETURN jsonb_build_object('success',false,'error','BRANCH_MISMATCH'); END IF;
  SELECT count(*)::int INTO v_count FROM public.sale_print_events WHERE sale_id=p_sale_id;
  IF v_count=0 AND NOT public.can_permission('pos.receipt.print') THEN
    RETURN jsonb_build_object('success',false,'error','PERMISSION_DENIED','permission','pos.receipt.print');
  END IF;
  IF v_count>0 AND NOT public.can_permission('pos.reprint') THEN
    IF p_approval_request_id IS NULL THEN RETURN jsonb_build_object('success',false,'error','MANAGER_APPROVAL_REQUIRED','action','reprint'); END IF;
    SELECT * INTO v_req FROM public.approval_requests WHERE id=p_approval_request_id FOR UPDATE;
    IF v_req.id IS NULL OR v_req.requester_id<>auth.uid() OR v_req.branch_id<>v_sale.branch_id OR v_req.action_type<>'reprint' OR v_req.entity_id IS DISTINCT FROM p_sale_id OR v_req.status<>'approved' OR v_req.expires_at<=now() THEN RETURN jsonb_build_object('success',false,'error','INVALID_APPROVAL'); END IF;
    UPDATE public.approval_requests SET status='consumed',consumed_at=now() WHERE id=v_req.id;
  END IF;
  INSERT INTO public.sale_print_events(sale_id,branch_id,user_id,print_number,approval_request_id)
  VALUES(p_sale_id,v_sale.branch_id,auth.uid(),v_count+1,CASE WHEN v_count>0 THEN p_approval_request_id ELSE NULL END)
  RETURNING id INTO v_event_id;
  INSERT INTO public.audit_log(user_id,user_email,action,entity,entity_id,details,branch_id)
  VALUES(auth.uid(),v_user.email,CASE WHEN v_count=0 THEN 'SALE_PRINTED' ELSE 'SALE_REPRINTED' END,'sale',p_sale_id,
    jsonb_build_object('print_number',v_count+1,'approval_request_id',p_approval_request_id),v_sale.branch_id);
  RETURN jsonb_build_object('success',true,'event_id',v_event_id,'print_number',v_count+1,'is_reprint',(v_count>0));
END $$;

REVOKE ALL ON FUNCTION public.authorize_sale_print(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.authorize_sale_print(uuid,uuid) TO authenticated,service_role;

DO $migration$
DECLARE v_def text; v_old text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='perform_pos_order_action';
  IF v_def IS NULL THEN RAISE EXCEPTION 'GRANULAR_POS_ACTION_MISSING'; END IF;
  v_old := E'  IF p_action_type NOT IN (''split_order'',''merge_order'',''transfer_order'') THEN\n    RETURN jsonb_build_object(''success'', false, ''error'', ''INVALID_ACTION'');\n  END IF;';
  v_new := v_old || E'\n\n  IF p_action_type = ''split_order'' AND NOT public.can_permission(''pos.order.split'') THEN\n    RETURN jsonb_build_object(''success'', false, ''error'', ''PERMISSION_DENIED'', ''permission'', ''pos.order.split'');\n  END IF;\n  IF p_action_type IN (''merge_order'',''transfer_order'') AND NOT public.can_permission(''pos.order.transfer'') THEN\n    RETURN jsonb_build_object(''success'', false, ''error'', ''PERMISSION_DENIED'', ''permission'', ''pos.order.transfer'');\n  END IF;';
  IF position(v_old IN v_def)=0 THEN RAISE EXCEPTION 'GRANULAR_POS_ACTION_PATTERN_CHANGED'; END IF;
  EXECUTE replace(v_def,v_old,v_new);
END;
$migration$;

ALTER FUNCTION public.perform_pos_order_action(text,uuid,jsonb,text) SET search_path = public, pg_temp;
