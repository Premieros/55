-- 030_repair_demo_admin_login.sql
-- Idempotently ensure the documented AuraOS demo admin can authenticate.
-- Scope is limited to the Demo Kitchen tenant and the documented demo email.

DO $$
DECLARE
  demo_restaurant_id UUID;
BEGIN
  SELECT id INTO demo_restaurant_id
  FROM restaurants
  WHERE slug = 'demo-kitchen'
  LIMIT 1;

  IF demo_restaurant_id IS NULL THEN
    INSERT INTO restaurants (id, name, slug, auto_approve_online_orders, delay_threshold_minutes)
    VALUES (
      '11111111-1111-1111-1111-111111111111'::UUID,
      'Demo Kitchen',
      'demo-kitchen',
      FALSE,
      15
    )
    ON CONFLICT (id) DO NOTHING;

    SELECT id INTO demo_restaurant_id
    FROM restaurants
    WHERE slug = 'demo-kitchen'
    LIMIT 1;
  END IF;

  IF demo_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'Demo Kitchen tenant could not be resolved';
  END IF;

  INSERT INTO users (restaurant_id, email, password_hash, name, role, is_active)
  VALUES (
    demo_restaurant_id,
    'admin@demo-kitchen.local',
    '$2a$10$d9plWLBZ2YUG.9.4wpJ8Feoc/hmCek5D8bX7xyWeSmkw2hhIXJR0e',
    'Admin User',
    'ADMIN',
    TRUE
  )
  ON CONFLICT (restaurant_id, email) DO UPDATE
  SET password_hash = EXCLUDED.password_hash,
      name = EXCLUDED.name,
      role = EXCLUDED.role,
      is_active = TRUE,
      updated_at = CURRENT_TIMESTAMP;
END $$;
