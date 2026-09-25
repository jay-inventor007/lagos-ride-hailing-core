-- Attempts to create invalid states. The database must reject every one.
-- Each block can be pasted on its own into the Supabase SQL Editor; table names include the
-- "ride." schema so no setup is needed. `npm run invalid` runs them all and prints each error.

-- test: 1. A rider requests a second ride while one is still in progress (R1)
-- Expected: rejected by trips_one_active_per_rider
insert into ride.trips (rider_id, request_key, city, fare_rule_id, currency,
                        pickup_lat, pickup_lng, pickup_address, dropoff_lat, dropoff_lng, dropoff_address,
                        estimated_distance_m, estimated_duration_s, quoted_fare_minor)
select t.rider_id, 'second-ride-test', t.city, t.fare_rule_id, t.currency,
       6.45, 3.40, 'Second pickup', 6.50, 3.45, 'Second dropoff', 7000, 1200, 200000
  from ride.trips t
 where t.status = 'in_progress'
 limit 1;

-- test: 2. A rating for a trip that hasn't finished (R5)
-- Expected: rejected by ratings_trip_must_be_completed
insert into ride.ratings (trip_id, rater_role, score, comment)
select t.id, 'rider', 5, 'Rating a ride that is still going'
  from ride.trips t
 where t.status = 'in_progress'
 limit 1;

-- test: 3. A payment for less than the trip's final fare (R4)
-- Expected: rejected by payments_match_trip_final_fare
insert into ride.payments (trip_id, amount_minor, currency, method, idempotency_key)
select t.id, t.final_fare_minor - 50000, t.currency, 'cash', 'underpayment-test'
  from ride.trips t
 where t.status = 'completed'
   and not exists (select 1 from ride.payments p where p.trip_id = t.id and p.status in ('pending', 'succeeded'))
 limit 1;

-- test: 4. A finished trip is moved back to in progress (state machine)
-- Expected: rejected by trips_allowed_transition
update ride.trips
   set status = 'in_progress'
 where id = (select id from ride.trips where status = 'completed' limit 1);

-- test: 5. A second Lagos price list that overlaps the current one (R3)
-- Expected: rejected by fare_rules_no_overlap
insert into ride.fare_rules (city, currency, base_fare_minor, per_km_minor, per_minute_minor, minimum_fare_minor, effective_from)
values ('Lagos', 'NGN', 60000, 18000, 3000, 120000, '2026-09-01 00:00+01');

-- test: 6. A trip in progress is cancelled after the rider is already in the car
-- Expected: rejected by trips_allowed_transition
update ride.trips
   set status = 'cancelled', cancelled_at = now(), cancelled_by = 'rider'
 where id = (select id from ride.trips where status = 'in_progress' limit 1);
