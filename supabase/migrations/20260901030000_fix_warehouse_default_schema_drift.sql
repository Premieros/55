-- 20260901030000_fix_warehouse_default_schema_drift.sql
-- Align warehouse schema with inventory-consumption logic used by kitchen sends.
-- Safe and idempotent for existing databases.

ALTER TABLE public.warehouses
  ADD COLUMN IF NOT EXISTS is_default boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_warehouses_branch_default
  ON public.warehouses (branch_id, is_default DESC, created_at ASC)
  WHERE is_active = true;
