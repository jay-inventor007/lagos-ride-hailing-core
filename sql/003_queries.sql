-- The queries behind the five key actions (see docs/1-requirements.md).
-- $1, $2, … are parameters filled in by the application. `npm run queries` runs them all, in
-- order, on one trip, and prints what each returns.

-- name: A1_request_ride
-- A1. Rider requests a ride. The quote comes from the price list in force right now (R3), and the
-- app's idempotency key makes a retried request return nothing instead of a second trip.
-- Index used: fare_rules_no_overlap (gist) finds the current price list.
-- $1 rider_id, $2 city, $3 request_key, $4 pickup_lat, $5 pickup_lng, $6 pickup_address,
-- $7 dropoff_lat, $8 dropoff_lng, $9 dropoff_address, $10 estimated_distance_m, $11 estimated_duration_s
insert into trips (rider_id, city, request_key, fare_rule_id, currency,
                   pickup_lat, pickup_lng, pickup_address, dropoff_lat, dropoff_lng, dropoff_address,
                   estimated_distance_m, estimated_duration_s, quoted_fare_minor)
select $1, $2, $3, fr.id, fr.currency, $4, $5, $6, $7, $8, $9, $10, $11, calculate_fare(fr.id, $10, $11)
  from fare_rules fr
 where fr.city = $2 and tstzrange(fr.effective_from, fr.effective_to) @> now()
on conflict (rider_id, request_key) do nothing
returning id, status, quoted_fare_minor, currency;

-- name: A2_find_nearby_requests
-- A2, part 1. Driver sees open requests near them, longest-waiting first.
-- Index used: trips_open_requests_location (only contains trips waiting for a driver).
-- $1 driver_lat, $2 driver_lng, $3 search box half-size in degrees (0.03 ≈ 3.3 km)
select id, pickup_address, dropoff_address, quoted_fare_minor, currency, requested_at
  from trips
 where status = 'requested'
   and pickup_lat between $1::float8 - $3::float8 and $1::float8 + $3::float8
   and pickup_lng between $2::float8 - $3::float8 and $2::float8 + $3::float8
 order by requested_at
 limit 10;

-- name: A2_accept
-- A2, part 2. Driver accepts. The "status = 'requested'" condition makes this safe when two drivers
-- tap Accept at once: the first one changes the row, the second updates nothing and is told it's
-- taken. The driver's name and car are copied onto the trip as they are right now (R6).
-- If the driver already has an unfinished trip, trips_one_active_per_driver rejects it (R2).
-- $1 trip_id, $2 driver_id
update trips t
   set status = 'accepted', driver_id = d.id, vehicle_id = v.id, accepted_at = now(),
       driver_name_snapshot = d.full_name, vehicle_plate_snapshot = v.plate_number,
       vehicle_description_snapshot = v.colour || ' ' || v.make || ' ' || v.model
  from drivers d
  join vehicles v on v.driver_id = d.id and v.is_active
 where t.id = $1 and t.status = 'requested'
   and d.id = $2 and d.is_online and d.deleted_at is null
returning t.id, t.status, t.driver_name_snapshot, t.vehicle_plate_snapshot, t.vehicle_description_snapshot;

-- name: A3_arrive
-- A3, step 1. Driver has reached the pickup point.
-- $1 trip_id, $2 driver_id
update trips set status = 'arrived', arrived_at = now()
 where id = $1 and driver_id = $2 and status = 'accepted'
returning id, status, arrived_at;

-- name: A3_start
-- A3, step 2. Rider is in the car.
-- $1 trip_id, $2 driver_id
update trips set status = 'in_progress', started_at = now()
 where id = $1 and driver_id = $2 and status = 'arrived'
returning id, status, started_at;

-- name: A3_complete
-- A3, step 3. Trip is over. The final fare uses the price list stored on the trip when it was
-- requested, not today's (R3).
-- $1 trip_id, $2 driver_id, $3 actual_distance_m, $4 actual_duration_s
update trips
   set status = 'completed', completed_at = now(),
       actual_distance_m = $3, actual_duration_s = $4,
       final_fare_minor = calculate_fare(fare_rule_id, $3, $4)
 where id = $1 and driver_id = $2 and status = 'in_progress'
returning id, status, quoted_fare_minor, final_fare_minor, currency;

-- name: A4_pay
-- A4, part 1. Rider pays. The amount is read from the trip, never sent by the app. The
-- idempotency key makes a retried request create nothing new (R4).
-- $1 trip_id, $2 rider_id, $3 method, $4 idempotency_key
insert into payments (trip_id, amount_minor, currency, method, idempotency_key)
select t.id, t.final_fare_minor, t.currency, $3, $4
  from trips t
 where t.id = $1 and t.rider_id = $2 and t.status = 'completed'
on conflict (idempotency_key) do nothing
returning id, status, amount_minor, currency, method;

-- name: A4_confirm
-- A4, part 2. The card processor confirms the charge (in reality, via a webhook).
-- $1 payment_id, $2 provider_reference
update payments set status = 'succeeded', provider_reference = $2
 where id = $1 and status = 'pending'
returning id, status, provider_reference;

-- name: A5_trip_history
-- A5, part 1. Rider's past trips, newest first, with the rating they gave if any.
-- Indexes used: trips_rider_history, then ratings_once_per_side for each row's rating.
-- $1 rider_id
select t.id, t.requested_at, t.status, t.pickup_address, t.dropoff_address,
       t.final_fare_minor, t.currency, t.driver_name_snapshot, t.vehicle_plate_snapshot,
       r.score as my_rating
  from trips t
  left join ratings r on r.trip_id = t.id and r.rater_role = 'rider'
 where t.rider_id = $1
 order by t.requested_at desc, t.id desc
 limit 20;

-- name: A5_rate
-- A5, part 2. Rider rates the driver. Only a completed trip can be rated
-- (ratings_trip_must_be_completed), once per side (ratings_once_per_side). The ratings_apply
-- trigger adds the score to the driver's totals in the same transaction.
-- $1 trip_id, $2 rider_id, $3 score, $4 comment
insert into ratings (trip_id, rater_role, score, comment)
select t.id, 'rider', $3, $4
  from trips t
 where t.id = $1 and t.rider_id = $2
returning id, rater_role, score;
