-- Sample data: 3 price lists, 3,000 riders, 400 drivers, ~500 cars, 20,000 finished trips,
-- plus some trips happening "right now", with their payments and ratings.
--
-- Trips obey every rule in the schema: each one is inserted as 'requested' and then moved through
-- its statuses with UPDATEs, exactly as the app would, so the transition trigger checks every step.

set search_path = ride, public;
select setseed(0.4242);

-- ─── Price lists ────────────────────────────────────────────────────────────────────────────
-- Lagos changed prices on 1 July: older trips were priced with the old list.
insert into fare_rules (city, currency, base_fare_minor, per_km_minor, per_minute_minor, minimum_fare_minor, effective_from, effective_to) values
  ('Lagos', 'NGN', 40000, 12000, 2000,  80000, '2026-01-01 00:00+01', '2026-07-01 00:00+01'),
  ('Lagos', 'NGN', 50000, 15000, 2500, 100000, '2026-07-01 00:00+01', null),
  ('Abuja', 'NGN', 45000, 13000, 2000,  90000, '2026-01-01 00:00+01', null);

-- ─── Riders and drivers ─────────────────────────────────────────────────────────────────────
insert into riders (full_name, phone, email, created_at, updated_at)
select (array['Ada','Chidi','Tunde','Ngozi','Emeka','Funke','Bola','Ifeoma','Musa','Aisha','Kelechi','Yemi','Segun','Zainab','Obinna','Temi'])[1 + floor(random() * 16)::int]
       || ' ' ||
       (array['Okafor','Adeyemi','Bello','Eze','Ogunleye','Nwosu','Ibrahim','Balogun','Okoro','Abubakar','Adebayo','Uche'])[1 + floor(random() * 12)::int],
       '+23480' || lpad(i::text, 8, '0'),
       case when random() < 0.7 then 'rider' || i || '@example.com' end,
       now() - interval '200 days', now() - interval '200 days'
  from generate_series(1, 3000) i;

-- Drivers 1-320 work in Lagos, 321-400 in Abuja (the city is implied by their trips).
insert into drivers (full_name, phone, licence_number, is_online, created_at, updated_at)
select (array['Ibrahim','Chukwuma','Olumide','Sani','Uchenna','Babatunde','Yusuf','Nnamdi','Kayode','Abdul','Femi','Ikenna'])[1 + floor(random() * 12)::int]
       || ' ' ||
       (array['Adewale','Okonkwo','Garba','Afolabi','Nwachukwu','Lawal','Ojo','Umar','Onyeka','Salami'])[1 + floor(random() * 10)::int],
       '+23481' || lpad(i::text, 8, '0'),
       case when i <= 320 then 'LAG' else 'ABJ' end || lpad(i::text, 6, '0'),
       random() < 0.6,
       now() - interval '200 days', now() - interval '200 days'
  from generate_series(1, 400) i;

-- Each driver's current car, plus an older retired car for 100 of them.
with numbered as (select id, row_number() over (order by phone) as n from drivers)
insert into vehicles (driver_id, plate_number, make, model, colour, year, is_active, created_at, updated_at, deleted_at)
select id,
       (array['KJA','LND','EKY','GGE','ABJ','BWR'])[1 + (n % 6)::int] || ' ' || lpad(n::text, 3, '0') || ' ' || chr(65 + (n % 26)::int) || chr(65 + ((n / 26) % 26)::int),
       (array['Toyota','Toyota','Honda','Hyundai','Kia','Lexus'])[1 + ((n * 7) % 6)::int],
       (array['Corolla','Camry','Accord','Elantra','Rio','RX 350'])[1 + ((n * 7) % 6)::int],
       (array['Silver','Black','White','Blue','Grey','Red'])[1 + floor(random() * 6)::int],
       2012 + floor(random() * 12)::int,
       true, now() - interval '150 days', now() - interval '150 days', null
  from numbered
union all
select id,
       'OLD ' || lpad(n::text, 3, '0') || ' XX', 'Toyota', 'Corolla', 'White', 2008 + (n % 4)::int,
       false, now() - interval '400 days', now() - interval '150 days', now() - interval '150 days'
  from numbered where n <= 100;

-- ─── 20,000 finished trips ──────────────────────────────────────────────────────────────────
-- 50 rounds. In each round every driver does one trip with a different rider, so no rider or
-- driver ever has two unfinished trips at once (the partial unique indexes would reject it).
create temporary table round_trips (
  trip_id uuid, driver_id uuid, vehicle_id uuid, driver_name text, plate text, car text, fate text
);

do $$
declare
  round_no int;
  round_start timestamptz;
begin
  for round_no in 1..50 loop
    round_start := now() - interval '125 days' + (round_no - 1) * interval '2 days 10 hours';
    truncate round_trips;

    with d as (
      select d.id as driver_id, v.id as vehicle_id, d.full_name, v.plate_number,
             v.colour || ' ' || v.make || ' ' || v.model as car,
             case when right(d.licence_number, 6)::int <= 320 then 'Lagos' else 'Abuja' end as city,
             row_number() over (order by d.phone) as n
        from drivers d join vehicles v on v.driver_id = d.id and v.is_active
    ), r as (
      select id as rider_id, row_number() over (order by phone) as n from riders
    ), planned as (
      select d.*, r.rider_id,
             round_start + random() * interval '2 days' as requested_at,
             case d.city when 'Lagos' then 6.43 + random() * 0.22 else 8.98 + random() * 0.14 end as p_lat,
             case d.city when 'Lagos' then 3.28 + random() * 0.30 else 7.38 + random() * 0.14 end as p_lng,
             (random() - 0.5) * 0.16 as d_lat, (random() - 0.5) * 0.16 as d_lng,
             4 + random() * 5 as speed_mps,
             random() as fate_roll
        from d join r on r.n = ((round_no * 400 + d.n) % 3000) + 1
    ), ins as (
      insert into trips (rider_id, request_key, city, fare_rule_id, currency,
                         pickup_lat, pickup_lng, pickup_address, dropoff_lat, dropoff_lng, dropoff_address,
                         estimated_distance_m, estimated_duration_s, quoted_fare_minor,
                         requested_at, created_at, updated_at)
      select p.rider_id, 'seed-' || round_no || '-' || p.n, p.city, fr.id, fr.currency,
             p.p_lat, p.p_lng, 'Pickup point ' || round_no || '-' || p.n,
             p.p_lat + p.d_lat + 0.005, p.p_lng + p.d_lng + 0.005, 'Dropoff point ' || round_no || '-' || p.n,
             dist.m, (dist.m / p.speed_mps)::int,
             calculate_fare(fr.id, dist.m, (dist.m / p.speed_mps)::int),
             p.requested_at, p.requested_at, p.requested_at
        from planned p
        join fare_rules fr on fr.city = p.city and tstzrange(fr.effective_from, fr.effective_to) @> p.requested_at
        cross join lateral (
          select greatest(800, round(1.3 * 111320 * sqrt((p.d_lat + 0.005) ^ 2
                 + ((p.d_lng + 0.005) * cos(radians(p.p_lat))) ^ 2)))::int as m) dist
      returning id, rider_id, request_key
    )
    insert into round_trips
    select ins.id, p.driver_id, p.vehicle_id, p.full_name, p.plate_number, p.car,
           case when p.fate_roll < 0.05 then 'cancel_requested'
                when p.fate_roll < 0.09 then 'cancel_accepted'
                when p.fate_roll < 0.12 then 'cancel_arrived'
                else 'complete' end
      from ins join planned p on ins.request_key = 'seed-' || round_no || '-' || p.n;

    -- Nobody accepted: the rider gave up, or the system timed out.
    update trips t set status = 'cancelled', cancelled_at = t.requested_at + interval '6 minutes',
           cancelled_by = case when random() < 0.5 then 'rider' else 'system' end,
           cancel_reason = 'No driver accepted', updated_at = t.requested_at + interval '6 minutes'
      from round_trips rt where rt.trip_id = t.id and rt.fate = 'cancel_requested';

    update trips t set status = 'accepted', driver_id = rt.driver_id, vehicle_id = rt.vehicle_id,
           driver_name_snapshot = rt.driver_name, vehicle_plate_snapshot = rt.plate, vehicle_description_snapshot = rt.car,
           accepted_at = t.requested_at + (30 + random() * 210) * interval '1 second',
           updated_at = t.requested_at + interval '4 minutes'
      from round_trips rt where rt.trip_id = t.id and rt.fate <> 'cancel_requested';

    update trips t set status = 'cancelled', cancelled_at = t.accepted_at + interval '3 minutes',
           cancelled_by = case when random() < 0.6 then 'rider' else 'driver' end,
           cancel_reason = 'Changed plans', updated_at = t.accepted_at + interval '3 minutes'
      from round_trips rt where rt.trip_id = t.id and rt.fate = 'cancel_accepted';

    update trips t set status = 'arrived', arrived_at = t.accepted_at + (3 + random() * 9) * interval '1 minute',
           updated_at = t.accepted_at + interval '12 minutes'
      from round_trips rt where rt.trip_id = t.id and rt.fate in ('cancel_arrived', 'complete');

    update trips t set status = 'cancelled', cancelled_at = t.arrived_at + interval '10 minutes',
           cancelled_by = 'driver', cancel_reason = 'Rider did not show up', updated_at = t.arrived_at + interval '10 minutes'
      from round_trips rt where rt.trip_id = t.id and rt.fate = 'cancel_arrived';

    update trips t set status = 'in_progress', started_at = t.arrived_at + (1 + random() * 4) * interval '1 minute',
           updated_at = t.arrived_at + interval '5 minutes'
      from round_trips rt where rt.trip_id = t.id and rt.fate = 'complete';

    -- The app records the real distance and time during the trip...
    update trips t set actual_distance_m = (t.estimated_distance_m * (0.9 + random() * 0.35))::int,
           actual_duration_s = (t.estimated_duration_s * (0.85 + random() * 0.5))::int
      from round_trips rt where rt.trip_id = t.id and rt.fate = 'complete';

    -- ...and the fare is worked out from them, using the price list from when it was requested (R3).
    update trips t set status = 'completed',
           final_fare_minor = calculate_fare(t.fare_rule_id, t.actual_distance_m, t.actual_duration_s),
           completed_at = t.started_at + t.actual_duration_s * interval '1 second',
           updated_at = t.started_at + t.actual_duration_s * interval '1 second'
      from round_trips rt where rt.trip_id = t.id and rt.fate = 'complete';
  end loop;
end;
$$;
drop table round_trips;

-- ─── Trips happening right now ──────────────────────────────────────────────────────────────
-- 120 riders waiting for a driver, spread over Lagos and Abuja.
insert into trips (rider_id, request_key, city, fare_rule_id, currency,
                   pickup_lat, pickup_lng, pickup_address, dropoff_lat, dropoff_lng, dropoff_address,
                   estimated_distance_m, estimated_duration_s, quoted_fare_minor, requested_at, created_at, updated_at)
select r.id, 'live-' || r.n, c.city, fr.id, fr.currency,
       c.lat, c.lng, 'Waiting rider ' || r.n, c.lat + 0.04, c.lng + 0.03, 'Destination ' || r.n,
       7200, 1500, calculate_fare(fr.id, 7200, 1500),
       now() - (r.n % 5) * interval '1 minute', now(), now()
  from (select id, row_number() over (order by phone) as n from riders) r
  cross join lateral (
    select case when r.n % 5 = 0 then 'Abuja' else 'Lagos' end as city,
           case when r.n % 5 = 0 then 8.98 + random() * 0.14 else 6.43 + random() * 0.22 end as lat,
           case when r.n % 5 = 0 then 7.38 + random() * 0.14 else 3.28 + random() * 0.30 end as lng) c
  join fare_rules fr on fr.city = c.city and fr.effective_to is null
 where r.n between 1 and 120;

-- 60 riders with a driver on the way, waiting, or in the car.
create temporary table live_pairs as
select r.id as rider_id, d.id as driver_id, v.id as vehicle_id, d.full_name, v.plate_number,
       v.colour || ' ' || v.make || ' ' || v.model as car, r.n
  from (select id, row_number() over (order by phone) as n from riders) r
  join (select id, full_name, row_number() over (order by phone) as n from drivers where right(licence_number, 6)::int <= 320) d
    on d.n = r.n - 120
  join vehicles v on v.driver_id = d.id and v.is_active
 where r.n between 121 and 180;

insert into trips (rider_id, request_key, city, fare_rule_id, currency,
                   pickup_lat, pickup_lng, pickup_address, dropoff_lat, dropoff_lng, dropoff_address,
                   estimated_distance_m, estimated_duration_s, quoted_fare_minor, requested_at, created_at, updated_at)
select lp.rider_id, 'live-' || lp.n, 'Lagos', fr.id, fr.currency,
       6.45 + (lp.n % 20) * 0.01, 3.30 + (lp.n % 25) * 0.01, 'Rider on trip ' || lp.n,
       6.52, 3.38, 'Destination ' || lp.n, 9000, 1800, calculate_fare(fr.id, 9000, 1800),
       now() - interval '20 minutes', now() - interval '20 minutes', now() - interval '20 minutes'
  from live_pairs lp join fare_rules fr on fr.city = 'Lagos' and fr.effective_to is null;

update trips t set status = 'accepted', driver_id = lp.driver_id, vehicle_id = lp.vehicle_id,
       driver_name_snapshot = lp.full_name, vehicle_plate_snapshot = lp.plate_number,
       vehicle_description_snapshot = lp.car, accepted_at = now() - interval '18 minutes'
  from live_pairs lp
 where t.rider_id = lp.rider_id and t.request_key = 'live-' || lp.n;
drop table live_pairs;

update trips set status = 'arrived', arrived_at = now() - interval '10 minutes'
 where request_key like 'live-%' and status = 'accepted' and right(request_key, 3)::int % 3 <> 0;
update trips set status = 'in_progress', started_at = now() - interval '8 minutes'
 where request_key like 'live-%' and status = 'arrived' and right(request_key, 3)::int % 3 = 1;

-- Drivers on a trip are online.
update drivers set is_online = true
 where id in (select driver_id from trips where status in ('accepted', 'arrived', 'in_progress'));

-- ─── Payments ───────────────────────────────────────────────────────────────────────────────
-- Some card payments were declined first.
insert into payments (trip_id, amount_minor, currency, method, status, idempotency_key, failure_reason, created_at, updated_at)
select id, final_fare_minor, currency, 'card', 'failed', 'seed-fail-' || id, 'Card declined by issuer',
       completed_at + interval '30 seconds', completed_at + interval '30 seconds'
  from trips where status = 'completed' and random() < 0.04;

-- 97% of finished trips are paid; the rest are still waiting (e.g. a disputed cash fare).
insert into payments (trip_id, amount_minor, currency, method, status, idempotency_key, provider_reference, created_at, updated_at)
select id, final_fare_minor, currency, m.method, 'succeeded', 'seed-pay-' || id,
       case when m.method = 'card' then 'PSK_' || left(md5(id::text), 16) end,
       completed_at + interval '1 minute', completed_at + interval '1 minute'
  from trips t
  cross join lateral (select case when random() < 0.65 then 'card' else 'cash' end as method) m
 where status = 'completed' and random() < 0.97;

-- ─── Ratings ────────────────────────────────────────────────────────────────────────────────
-- The ratings trigger adds each score to the driver's or rider's totals.
insert into ratings (trip_id, rater_role, score, comment, created_at, updated_at)
select id, 'rider',
       case when s < 0.55 then 5 when s < 0.85 then 4 when s < 0.95 then 3 when s < 0.98 then 2 else 1 end,
       case when s >= 0.95 then 'Driver was late and rude' end,
       completed_at + interval '5 minutes', completed_at + interval '5 minutes'
  from trips cross join lateral (select random() as s) x
 where status = 'completed' and random() < 0.7;

insert into ratings (trip_id, rater_role, score, created_at, updated_at)
select id, 'driver', case when random() < 0.8 then 5 else 4 end,
       completed_at + interval '2 minutes', completed_at + interval '2 minutes'
  from trips where status = 'completed' and random() < 0.5;

-- ─── Deleted accounts ───────────────────────────────────────────────────────────────────────
-- Five riders deleted their accounts. Personal details are gone; their trips and payments stay.
update riders set deleted_at = now() - interval '3 days', full_name = null, phone = null, email = null
 where id in (select id from riders r
               where not exists (select 1 from trips t where t.rider_id = r.id
                                  and t.status in ('requested', 'accepted', 'arrived', 'in_progress'))
               order by phone desc limit 5);

-- Refresh the planner's statistics so query plans reflect this data.
analyze fare_rules, riders, drivers, vehicles, trips, payments, ratings;
