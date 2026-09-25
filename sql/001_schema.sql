-- Ride-hailing data model. Everything lives in its own schema, "ride".
-- Every constraint that makes an invalid state impossible is named, so the error message names it.

create extension if not exists btree_gist; -- lets one constraint combine "same city" and "overlapping dates"

create schema if not exists ride;
set search_path = ride, public;

-- updated_at is set automatically on every change, unless the statement sets it itself.
create function set_updated_at() returns trigger language plpgsql as $$
begin
  if new.updated_at is not distinct from old.updated_at then
    new.updated_at = now();
  end if;
  return new;
end;
$$;

-- ─── Price lists ────────────────────────────────────────────────────────────────────────────

create table fare_rules (
  id                 uuid primary key default gen_random_uuid(),
  city               text not null,
  currency           char(3) not null check (currency ~ '^[A-Z]{3}$'),
  base_fare_minor    bigint not null check (base_fare_minor >= 0),
  per_km_minor       bigint not null check (per_km_minor >= 0),
  per_minute_minor   bigint not null check (per_minute_minor >= 0),
  minimum_fare_minor bigint not null check (minimum_fare_minor >= 0),
  effective_from     timestamptz not null,
  effective_to       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint fare_rules_valid_period check (effective_to is null or effective_to > effective_from),
  -- Two price lists for the same city can never cover the same moment.
  constraint fare_rules_no_overlap exclude using gist (city with =, tstzrange(effective_from, effective_to) with &&),
  -- Targets for the trips foreign key below: a trip's city and currency must match its price list.
  constraint fare_rules_id_city_currency unique (id, city, currency)
);

-- The fare for a distance and duration under one price list, rounded to the nearest ₦50.
-- Integer kobo in, integer kobo out.
create function calculate_fare(rule_id uuid, distance_m integer, duration_s integer) returns bigint
language sql stable as $$
  select (round(greatest(
            r.minimum_fare_minor,
            r.base_fare_minor + r.per_km_minor * distance_m / 1000.0 + r.per_minute_minor * duration_s / 60.0
          ) / 5000.0) * 5000)::bigint
    from fare_rules r
   where r.id = rule_id
$$;

-- ─── People and cars ────────────────────────────────────────────────────────────────────────

create table riders (
  id           uuid primary key default gen_random_uuid(),
  full_name    text,
  phone        text unique check (phone ~ '^\+234[0-9]{10}$'),
  email        text unique,
  rating_sum   integer not null default 0 check (rating_sum >= 0),
  rating_count integer not null default 0 check (rating_count >= 0),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  -- A live account has a name and phone; a deleted one has had all personal details removed.
  constraint riders_live_has_details check (deleted_at is not null or (full_name is not null and phone is not null)),
  constraint riders_deleted_is_anonymised check (deleted_at is null or (full_name is null and phone is null and email is null)),
  -- Every score is 1 to 5, so the total must sit between count×1 and count×5.
  constraint riders_rating_totals_consistent check (rating_sum between rating_count and rating_count * 5)
);

create table drivers (
  id             uuid primary key default gen_random_uuid(),
  full_name      text,
  phone          text unique check (phone ~ '^\+234[0-9]{10}$'),
  licence_number text unique,
  is_online      boolean not null default false,
  rating_sum     integer not null default 0 check (rating_sum >= 0),
  rating_count   integer not null default 0 check (rating_count >= 0),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  constraint drivers_live_has_details check (deleted_at is not null or (full_name is not null and phone is not null and licence_number is not null)),
  constraint drivers_deleted_is_anonymised check (deleted_at is null or (full_name is null and phone is null and licence_number is null)),
  constraint drivers_deleted_is_offline check (deleted_at is null or not is_online),
  constraint drivers_rating_totals_consistent check (rating_sum between rating_count and rating_count * 5)
);

create table vehicles (
  id           uuid primary key default gen_random_uuid(),
  driver_id    uuid not null references drivers(id),
  plate_number text not null,
  make         text not null,
  model        text not null,
  colour       text not null,
  year         integer not null check (year between 1990 and 2100),
  is_active    boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  constraint vehicles_deleted_is_inactive check (deleted_at is null or not is_active),
  -- Target for the trips foreign key below: a trip's car must belong to the trip's driver.
  constraint vehicles_id_driver unique (id, driver_id)
);
-- A driver drives one car at a time.
create unique index vehicles_one_active_per_driver on vehicles (driver_id) where is_active;
-- A plate belongs to one car on the road; a retired car's plate can be registered again.
create unique index vehicles_plate_in_use on vehicles (plate_number) where deleted_at is null;
-- "List my cars" in the driver app.
create index vehicles_driver on vehicles (driver_id);

-- ─── Trips ──────────────────────────────────────────────────────────────────────────────────

-- The allowed status changes. Anything not listed here is forbidden.
create table trip_status_transitions (
  from_status text not null,
  to_status   text not null,
  primary key (from_status, to_status)
);
insert into trip_status_transitions (from_status, to_status) values
  ('requested',   'accepted'),
  ('requested',   'cancelled'),
  ('accepted',    'arrived'),
  ('accepted',    'cancelled'),
  ('arrived',     'in_progress'),
  ('arrived',     'cancelled'),
  ('in_progress', 'completed');

create table trips (
  id                           uuid primary key default gen_random_uuid(),
  rider_id                     uuid not null references riders(id),
  request_key                  text not null,
  city                         text not null,
  fare_rule_id                 uuid not null,
  currency                     char(3) not null,
  status                       text not null default 'requested'
                               check (status in ('requested', 'accepted', 'arrived', 'in_progress', 'completed', 'cancelled')),

  pickup_lat                   double precision not null check (pickup_lat between -90 and 90),
  pickup_lng                   double precision not null check (pickup_lng between -180 and 180),
  pickup_address               text not null,
  dropoff_lat                  double precision not null check (dropoff_lat between -90 and 90),
  dropoff_lng                  double precision not null check (dropoff_lng between -180 and 180),
  dropoff_address              text not null,
  estimated_distance_m         integer not null check (estimated_distance_m > 0),
  estimated_duration_s         integer not null check (estimated_duration_s > 0),
  quoted_fare_minor            bigint not null check (quoted_fare_minor > 0),

  driver_id                    uuid references drivers(id),
  vehicle_id                   uuid,
  driver_name_snapshot         text,
  vehicle_plate_snapshot       text,
  vehicle_description_snapshot text,

  actual_distance_m            integer check (actual_distance_m > 0),
  actual_duration_s            integer check (actual_duration_s > 0),
  final_fare_minor             bigint check (final_fare_minor > 0),

  requested_at                 timestamptz not null default now(),
  accepted_at                  timestamptz,
  arrived_at                   timestamptz,
  started_at                   timestamptz,
  completed_at                 timestamptz,
  cancelled_at                 timestamptz,
  cancelled_by                 text check (cancelled_by in ('rider', 'driver', 'system')),
  cancel_reason                text,
  created_at                   timestamptz not null default now(),
  updated_at                   timestamptz not null default now(),

  -- Retrying "request a ride" with the same key can't create a second trip.
  constraint trips_request_key_unique unique (rider_id, request_key),
  -- The price list must be for this trip's city and currency.
  constraint trips_fare_rule_fkey foreign key (fare_rule_id, city, currency)
    references fare_rules (id, city, currency),
  -- The car must be one of this driver's cars.
  constraint trips_vehicle_belongs_to_driver foreign key (vehicle_id, driver_id)
    references vehicles (id, driver_id),
  -- Targets for the ratings and payments foreign keys (see those tables).
  constraint trips_id_status unique (id, status),
  constraint trips_id_final_fare unique (id, final_fare_minor, currency),

  constraint trips_pickup_differs_from_dropoff check (pickup_lat <> dropoff_lat or pickup_lng <> dropoff_lng),

  -- What each status requires. Together these mean a trip's columns can't disagree with its status.
  constraint trips_requested_has_no_driver check (
    status <> 'requested' or (driver_id is null and accepted_at is null)),
  constraint trips_accepted_has_driver_and_car check (
    status not in ('accepted', 'arrived', 'in_progress', 'completed')
    or (driver_id is not null and vehicle_id is not null and accepted_at is not null
        and driver_name_snapshot is not null and vehicle_plate_snapshot is not null)),
  constraint trips_arrived_has_arrival_time check (
    status not in ('arrived', 'in_progress', 'completed') or arrived_at is not null),
  constraint trips_started_has_start_time check (
    status not in ('in_progress', 'completed') or started_at is not null),
  constraint trips_completed_iff_final_fare check (
    (status = 'completed') = (completed_at is not null and final_fare_minor is not null
                              and actual_distance_m is not null and actual_duration_s is not null)),
  constraint trips_cancelled_iff_cancel_details check (
    (status = 'cancelled') = (cancelled_at is not null and cancelled_by is not null)),
  constraint trips_driver_cancel_needs_driver check (cancelled_by is distinct from 'driver' or driver_id is not null),

  -- Timestamps happen in order.
  constraint trips_times_in_order check (
    (accepted_at  is null or accepted_at  >= requested_at) and
    (arrived_at   is null or arrived_at   >= accepted_at)  and
    (started_at   is null or started_at   >= arrived_at)   and
    (completed_at is null or completed_at >= started_at)   and
    (cancelled_at is null or cancelled_at >= requested_at))
);

-- R1: a rider has at most one trip that isn't finished.
create unique index trips_one_active_per_rider on trips (rider_id)
  where status in ('requested', 'accepted', 'arrived', 'in_progress');
-- R2: a driver has at most one trip that isn't finished.
create unique index trips_one_active_per_driver on trips (driver_id)
  where status in ('accepted', 'arrived', 'in_progress');
-- A2: open requests near a driver. Only requests waiting for a driver are in this index.
create index trips_open_requests_location on trips (pickup_lat, pickup_lng)
  where status = 'requested';
-- A5: a rider's trip history, newest first.
create index trips_rider_history on trips (rider_id, requested_at desc, id desc);
-- A driver's completed trips, newest first (earnings screen).
create index trips_driver_completed on trips (driver_id, completed_at desc, id desc)
  where status = 'completed';

-- New trips always start as requested, and some columns can never change once set.
create function trips_guard_insert() returns trigger language plpgsql as $$
begin
  if new.status <> 'requested' then
    raise exception 'A new trip must start as requested, not %', new.status
      using errcode = 'check_violation', constraint = 'trips_start_as_requested';
  end if;
  return new;
end;
$$;
create trigger trips_guard_insert before insert on trips
  for each row execute function trips_guard_insert();

-- Every status change must be in trip_status_transitions.
create function trips_guard_update() returns trigger language plpgsql as $$
begin
  if new.status is distinct from old.status and not exists (
       select 1 from trip_status_transitions t
        where t.from_status = old.status and t.to_status = new.status) then
    raise exception 'Trip % cannot go from % to %', old.id, old.status, new.status
      using errcode = 'check_violation', constraint = 'trips_allowed_transition';
  end if;
  if new.rider_id <> old.rider_id or new.quoted_fare_minor <> old.quoted_fare_minor
     or new.fare_rule_id <> old.fare_rule_id or new.currency <> old.currency then
    raise exception 'A trip''s rider, quoted fare, and price list can''t change'
      using errcode = 'check_violation', constraint = 'trips_fixed_at_request';
  end if;
  if old.driver_id is not null and new.driver_id is distinct from old.driver_id then
    raise exception 'A trip''s driver can''t change once assigned'
      using errcode = 'check_violation', constraint = 'trips_driver_fixed';
  end if;
  return new;
end;
$$;
create trigger trips_guard_update before update on trips
  for each row execute function trips_guard_update();
create trigger trips_updated_at before update on trips for each row execute function set_updated_at();

-- ─── Payments ───────────────────────────────────────────────────────────────────────────────

create table payments (
  id                 uuid primary key default gen_random_uuid(),
  trip_id            uuid not null,
  amount_minor       bigint not null check (amount_minor > 0),
  currency           char(3) not null,
  method             text not null check (method in ('card', 'cash')),
  status             text not null default 'pending' check (status in ('pending', 'succeeded', 'failed', 'refunded')),
  idempotency_key    text not null,
  provider_reference text,
  failure_reason     text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint payments_idempotency_key_unique unique (idempotency_key),
  constraint payments_provider_reference_unique unique (provider_reference),
  -- R4: a payment points at a trip AND that trip's final fare and currency. So the amount must be
  -- exactly the final fare, and a trip with no final fare yet (not completed) can't be paid.
  -- ON UPDATE RESTRICT: once paid, the trip's final fare can't be changed underneath the payment.
  constraint payments_match_trip_final_fare foreign key (trip_id, amount_minor, currency)
    references trips (id, final_fare_minor, currency) on update restrict,
  constraint payments_card_success_has_reference check (
    method <> 'card' or status not in ('succeeded', 'refunded') or provider_reference is not null),
  constraint payments_cash_has_no_reference check (method <> 'cash' or provider_reference is null),
  constraint payments_failed_iff_reason check ((status = 'failed') = (failure_reason is not null))
);
-- R4: at most one payment per trip that is in flight or has gone through.
create unique index payments_one_live_per_trip on payments (trip_id) where status in ('pending', 'succeeded');
-- "Show this trip's payments."
create index payments_trip on payments (trip_id);
create trigger payments_updated_at before update on payments for each row execute function set_updated_at();

-- ─── Ratings ────────────────────────────────────────────────────────────────────────────────

create table ratings (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null,
  -- Always 'completed'. With the foreign key below, the database only accepts a rating whose trip
  -- currently has status 'completed'. (R5)
  trip_status text not null default 'completed' check (trip_status = 'completed'),
  rater_role  text not null check (rater_role in ('rider', 'driver')),
  score       smallint not null check (score between 1 and 5),
  comment     text check (length(comment) <= 500),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint ratings_trip_must_be_completed foreign key (trip_id, trip_status)
    references trips (id, status) on update restrict,
  -- R5: once by each side.
  constraint ratings_once_per_side unique (trip_id, rater_role)
);
create trigger ratings_updated_at before update on ratings for each row execute function set_updated_at();

-- Keep the rating totals on drivers and riders in step with ratings, in the same transaction.
create function ratings_apply() returns trigger language plpgsql as $$
begin
  if new.rater_role = 'rider' then
    update drivers d set rating_sum = d.rating_sum + new.score, rating_count = d.rating_count + 1
      from trips t where t.id = new.trip_id and d.id = t.driver_id;
  else
    update riders r set rating_sum = r.rating_sum + new.score, rating_count = r.rating_count + 1
      from trips t where t.id = new.trip_id and r.id = t.rider_id;
  end if;
  return null;
end;
$$;
create trigger ratings_apply after insert on ratings for each row execute function ratings_apply();

-- A score is final. Only the comment may be edited (e.g. to remove abuse).
create function ratings_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' or new.score <> old.score or new.trip_id <> old.trip_id or new.rater_role <> old.rater_role then
    raise exception 'Ratings can''t be deleted, and their score can''t change'
      using errcode = 'check_violation', constraint = 'ratings_are_final';
  end if;
  return new;
end;
$$;
create trigger ratings_guard before update or delete on ratings for each row execute function ratings_guard();

create trigger fare_rules_updated_at before update on fare_rules for each row execute function set_updated_at();
create trigger riders_updated_at before update on riders for each row execute function set_updated_at();
create trigger drivers_updated_at before update on drivers for each row execute function set_updated_at();
create trigger vehicles_updated_at before update on vehicles for each row execute function set_updated_at();
