const { Pool } = require('pg');
const bcrypt = require('bcryptjs');

const email = 'sayed3la2@gmail.com';
const expectedProjectRef = 'limpprtlwtlvfwezkulq';
const raw = process.env.DATABASE_URL;
const password = process.env.AURAOS_SUPER_ADMIN_PASSWORD;

if (!raw) throw new Error('DATABASE_URL is missing');
if (!password || password.length < 8) throw new Error('AURAOS_SUPER_ADMIN_PASSWORD is missing or too short');

const u = new URL(raw);
const identity = `${u.hostname} ${decodeURIComponent(u.username)}`;
if (!identity.includes(expectedProjectRef)) {
  throw new Error(`DATABASE IDENTITY MISMATCH: expected ${expectedProjectRef}`);
}
u.searchParams.set('sslmode', 'require');
if (u.hostname.endsWith('.pooler.supabase.com')) u.searchParams.set('uselibpqcompat', 'true');

const pool = new Pool({ connectionString: u.toString(), connectionTimeoutMillis: 10000 });

(async () => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const existing = await client.query(
      `SELECT id, restaurant_id FROM users WHERE lower(email) = $1 ORDER BY created_at`,
      [email],
    );
    if (existing.rowCount > 1) throw new Error(`Refusing bootstrap: duplicate email ${email}`);

    const hash = await bcrypt.hash(password, 12);
    let userId;

    if (existing.rowCount === 1) {
      userId = existing.rows[0].id;
      await client.query(
        `UPDATE users
         SET password_hash = $1, name = 'Sayed Alaa', role = 'ADMIN', is_active = TRUE, updated_at = NOW()
         WHERE id = $2`,
        [hash, userId],
      );
    } else {
      const restaurant = await client.query(
        `INSERT INTO restaurants (name, slug, auto_approve_online_orders, delay_threshold_minutes)
         VALUES ('AuraOS Platform', 'auraos-platform', FALSE, 15)
         ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name
         RETURNING id`,
      );
      const inserted = await client.query(
        `INSERT INTO users (restaurant_id, email, password_hash, name, role, is_active)
         VALUES ($1, $2, $3, 'Sayed Alaa', 'ADMIN', TRUE)
         RETURNING id`,
        [restaurant.rows[0].id, email, hash],
      );
      userId = inserted.rows[0].id;
    }

    await client.query('COMMIT');

    const verify = await client.query(
      `SELECT email, name, role, is_active FROM users WHERE id = $1`,
      [userId],
    );
    const row = verify.rows[0];
    if (!row || row.email.toLowerCase() !== email || row.role !== 'ADMIN' || !row.is_active) {
      throw new Error('Super admin bootstrap verification failed');
    }

    console.log(`AuraOS platform account ready: ${email}`);
    console.log('Role ADMIN and active=true verified. Password was not printed.');
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    client.release();
    await pool.end();
  }
})().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
