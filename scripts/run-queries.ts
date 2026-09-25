// Runs the five actions from sql/003_queries.sql on one new trip, from request to rating, and prints
// what each returns. Everything happens inside a transaction that is rolled back at the end, so the
// sample data is unchanged and this can be run any number of times.
//
// Then prints the query plans (EXPLAIN ANALYZE) for the two heaviest reads.
//
// Output is also written to docs/evidence/.

import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pool, readNamedBlocks, sqlDir } from './db.js';

const q = await readNamedBlocks('003_queries.sql', 'name');
const lines: string[] = [];
const out = (text = '') => {
  console.log(text);
  lines.push(text);
};
const show = (rows: unknown[]) => rows.forEach((row) => out('  ' + JSON.stringify(row)));
const naira = (kobo: number | string) => `₦${(Number(kobo) / 100).toLocaleString('en-NG')}`;

const client = await pool.connect();
try {
  await client.query('begin');

  // A rider with history and nothing in progress, and an online Lagos driver who is free.
  const rider = (await client.query(`
    select r.id, r.full_name from riders r
     where r.deleted_at is null
       and not exists (select 1 from trips t where t.rider_id = r.id and t.status in ('requested','accepted','arrived','in_progress'))
       and exists (select 1 from trips t where t.rider_id = r.id and t.city = 'Lagos' and t.status = 'completed')
     order by r.phone limit 1 offset 200`)).rows[0];
  const driver = (await client.query(`
    select d.id, d.full_name, d.rating_sum, d.rating_count from drivers d
     where d.is_online and d.deleted_at is null and right(d.licence_number, 6)::int <= 320
       and not exists (select 1 from trips t where t.driver_id = d.id and t.status in ('accepted','arrived','in_progress'))
     order by d.phone limit 1 offset 100`)).rows[0];
  out(`Rider:  ${rider.full_name} (${rider.id})`);
  out(`Driver: ${driver.full_name} (${driver.id})`);

  out('\nA1  Request a ride from Yaba to Ikeja');
  const requestParams = [rider.id, 'Lagos', 'demo-request-1', 6.5095, 3.3711, 'Yaba Tech main gate, Herbert Macaulay Way',
    6.6018, 3.3515, 'Ikeja City Mall, Obafemi Awolowo Way', 14800, 2700];
  const requested = (await client.query(q.get('A1_request_ride')!, requestParams)).rows;
  show(requested);
  const trip = requested[0];
  out(`  quoted fare: ${naira(trip.quoted_fare_minor)}`);

  out('\nA1  Same request again with the same key (the app retried after a timeout)');
  const retried = (await client.query(q.get('A1_request_ride')!, requestParams)).rows;
  out(`  rows returned: ${retried.length} (no second trip)`);

  out('\nA2  Driver near Yaba looks for open requests within about 3 km');
  const nearby = (await client.query(q.get('A2_find_nearby_requests')!, [6.515, 3.375, 0.03])).rows;
  show(nearby.map((r) => ({ id: r.id, pickup: r.pickup_address, fare: naira(r.quoted_fare_minor) })));
  out(`  our trip is in the list: ${nearby.some((r) => r.id === trip.id)}`);

  out('\nA2  Driver accepts');
  show((await client.query(q.get('A2_accept')!, [trip.id, driver.id])).rows);

  out('\nA2  A second driver taps Accept a moment later');
  const other = (await client.query(`
    select d.id from drivers d where d.is_online and d.id <> $1
       and not exists (select 1 from trips t where t.driver_id = d.id and t.status in ('accepted','arrived','in_progress'))
     order by d.phone limit 1`, [driver.id])).rows[0];
  const late = (await client.query(q.get('A2_accept')!, [trip.id, other.id])).rows;
  out(`  rows updated: ${late.length} (the trip is already taken)`);

  out('\nA3  Driver arrives, starts, and completes the trip (15.6 km, 52 minutes)');
  show((await client.query(q.get('A3_arrive')!, [trip.id, driver.id])).rows);
  show((await client.query(q.get('A3_start')!, [trip.id, driver.id])).rows);
  const completed = (await client.query(q.get('A3_complete')!, [trip.id, driver.id, 15600, 3120])).rows;
  show(completed);
  out(`  quoted ${naira(completed[0].quoted_fare_minor)}, final ${naira(completed[0].final_fare_minor)} (longer trip than estimated)`);
  out('  (The times are all the same because this demo runs in one transaction, and now() is the');
  out('   transaction\'s start time. In the app each step is its own request, minutes apart.)');

  out('\nA4  Rider pays by card');
  const payment = (await client.query(q.get('A4_pay')!, [trip.id, rider.id, 'card', 'demo-pay-1'])).rows;
  show(payment);
  out('\nA4  Card processor confirms');
  show((await client.query(q.get('A4_confirm')!, [payment[0].id, 'PSK_demo_0001'])).rows);
  out('\nA4  The pay request is retried with the same key');
  const repay = (await client.query(q.get('A4_pay')!, [trip.id, rider.id, 'card', 'demo-pay-1'])).rows;
  out(`  rows returned: ${repay.length} (no second payment)`);

  out('\nA5  Rider rates the driver 5 stars');
  show((await client.query(q.get('A5_rate')!, [trip.id, rider.id, 5, 'Smooth ride, AC was working'])).rows);
  const after = (await client.query('select rating_sum, rating_count from drivers where id = $1', [driver.id])).rows[0];
  out(`  driver's rating totals: ${driver.rating_sum}/${driver.rating_count} → ${after.rating_sum}/${after.rating_count}` +
    ` (average ${(after.rating_sum / after.rating_count).toFixed(2)})`);

  out('\nA5  Rider opens their trip history (newest 5 shown)');
  const history = (await client.query(q.get('A5_trip_history')!, [rider.id])).rows;
  show(history.slice(0, 5).map((h) => ({
    requested: h.requested_at.toISOString().slice(0, 16), status: h.status,
    fare: h.final_fare_minor ? naira(h.final_fare_minor) : null, driver: h.driver_name_snapshot, my_rating: h.my_rating,
  })));

  await client.query('rollback');
  out('\n(Rolled back: the sample data is unchanged.)');

  // ─── Query plans for the two heaviest reads ───────────────────────────────────────────────
  const plans: string[] = [];
  const explain = async (title: string, sql: string, params: unknown[]) => {
    const { rows } = await client.query(`explain (analyze, buffers, costs off) ${sql}`, params);
    const text = [`${title}`, '', ...rows.map((r) => r['QUERY PLAN'])].join('\n');
    plans.push(text);
    out(`\n${text}`);
  };
  out('\n──────────── Query plans ────────────');
  await explain('A2_find_nearby_requests: open requests within ~3 km of a driver in Yaba',
    q.get('A2_find_nearby_requests')!, [6.515, 3.375, 0.03]);
  await explain('A5_trip_history: one rider\'s 20 most recent trips with their ratings',
    q.get('A5_trip_history')!, [rider.id]);

  const evidence = path.join(sqlDir, '..', 'docs', 'evidence');
  await writeFile(path.join(evidence, 'five-actions.txt'), lines.join('\n').split('──────────── Query plans')[0].trimEnd() + '\n');
  await writeFile(path.join(evidence, 'query-plans.txt'), plans.join('\n\n' + '─'.repeat(80) + '\n\n') + '\n');
} catch (err) {
  await client.query('rollback');
  throw err;
} finally {
  client.release();
  await pool.end();
}
