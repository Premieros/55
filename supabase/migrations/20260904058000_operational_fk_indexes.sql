-- Cover operational foreign keys reported by Supabase Advisor.
CREATE INDEX IF NOT EXISTS idx_approval_policies_branch_id ON public.approval_policies(branch_id);
CREATE INDEX IF NOT EXISTS idx_approval_policies_approver_user_id ON public.approval_policies(approver_user_id);
CREATE INDEX IF NOT EXISTS idx_approval_policies_created_by ON public.approval_policies(created_by);
CREATE INDEX IF NOT EXISTS idx_approval_requests_approver_id ON public.approval_requests(approver_id);

CREATE INDEX IF NOT EXISTS idx_inventory_ledger_warehouse_id ON public.inventory_ledger(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_inventory_ledger_created_by ON public.inventory_ledger(created_by);
CREATE INDEX IF NOT EXISTS idx_inventory_unit_batches_warehouse_id ON public.inventory_unit_batches(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_inventory_unit_entries_warehouse_id ON public.inventory_unit_entries(warehouse_id);

CREATE INDEX IF NOT EXISTS idx_order_inventory_consumptions_product_id ON public.order_inventory_consumptions(product_id);
CREATE INDEX IF NOT EXISTS idx_order_inventory_consumptions_raw_material_id ON public.order_inventory_consumptions(raw_material_id);
CREATE INDEX IF NOT EXISTS idx_order_inventory_consumptions_warehouse_id ON public.order_inventory_consumptions(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_order_items_product_id ON public.order_items(product_id);
CREATE INDEX IF NOT EXISTS idx_order_kitchen_sends_sent_by ON public.order_kitchen_sends(sent_by);
CREATE INDEX IF NOT EXISTS idx_order_kitchen_voids_approval_request_id ON public.order_kitchen_voids(approval_request_id);
CREATE INDEX IF NOT EXISTS idx_order_kitchen_voids_product_id ON public.order_kitchen_voids(product_id);
CREATE INDEX IF NOT EXISTS idx_order_kitchen_voids_voided_by ON public.order_kitchen_voids(voided_by);
CREATE INDEX IF NOT EXISTS idx_orders_cashier_id ON public.orders(cashier_id);
CREATE INDEX IF NOT EXISTS idx_orders_customer_id ON public.orders(customer_id);

CREATE INDEX IF NOT EXISTS idx_sale_item_inventory_effects_warehouse_id ON public.sale_item_inventory_effects(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_sale_print_events_approval_request_id ON public.sale_print_events(approval_request_id);
CREATE INDEX IF NOT EXISTS idx_sale_print_events_branch_id ON public.sale_print_events(branch_id);
CREATE INDEX IF NOT EXISTS idx_sale_print_events_user_id ON public.sale_print_events(user_id);

CREATE INDEX IF NOT EXISTS idx_user_branch_access_branch_id ON public.user_branch_access(branch_id);
CREATE INDEX IF NOT EXISTS idx_waste_entries_inventory_unit_id ON public.waste_entries(inventory_unit_id);
CREATE INDEX IF NOT EXISTS idx_waste_entries_product_id ON public.waste_entries(product_id);
CREATE INDEX IF NOT EXISTS idx_waste_entries_raw_material_id ON public.waste_entries(raw_material_id);
CREATE INDEX IF NOT EXISTS idx_waste_entries_warehouse_id ON public.waste_entries(warehouse_id);

CREATE INDEX IF NOT EXISTS idx_stock_counts_warehouse_id ON public.stock_counts(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_stock_counts_created_by ON public.stock_counts(created_by);
CREATE INDEX IF NOT EXISTS idx_stock_counts_submitted_by ON public.stock_counts(submitted_by);
CREATE INDEX IF NOT EXISTS idx_stock_counts_approved_by ON public.stock_counts(approved_by);
