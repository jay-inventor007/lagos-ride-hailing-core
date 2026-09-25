// Builds the "ride" schema from scratch: drops it if it exists, creates every table, constraint,
// and index, then loads the sample data. Only the "ride" schema is touched.

import { pool, readSql } from './db.js';

const client = await pool.connect();
try {
  const started = Date.now();
  await client.query('drop schema if exists ride cascade');
  await client.query(await readSql('001_schema.sql'));
  console.log(`schema created (${Date.now() - started}ms)`);

  const seeding = Date.now();
  await client.query(await readSql('002_seed.sql'));
  console.log(`sample data loaded (${((Date.now() - seeding) / 1000).toFixed(1)}s)`);

  const { rows } = await client.query(`
    select 'fare_rules' as "table", count(*)::int as "rows" from fare_rules
    union all select 'riders', count(*)::int from riders
    union all select 'drivers', count(*)::int from drivers
    union all select 'vehicles', count(*)::int from vehicles
    union all select 'trips', count(*)::int from trips
    union all select 'payments', count(*)::int from payments
    union all select 'ratings', count(*)::int from ratings`);
  console.table(rows);

  const statuses = await client.query(`select status, count(*)::int as trips from trips group by status order by trips desc`);
  console.table(statuses.rows);
} finally {
  client.release();
  await pool.end();
}
