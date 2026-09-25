# 4. API design

The API is designed on top of the model in [2. Data model](2-data-model.md). It is **not built**
in this task: this document is the contract a second engineer would implement.

- [Conventions](#conventions)
- [The five key actions](#the-five-key-actions): A1 to A5, in full
- [Other operations per entity](#other-operations-per-entity)
- [Representations](#representations)
- [Over-fetching: REST vs GraphQL](#over-fetching-rest-vs-graphql)
- [Real-time: watching the driver approach](#real-time-watching-the-driver-approach)

---

## Conventions

**Base path.** Every path starts with `/api/v1`. A breaking change ships as `/api/v2` while `/v1`
keeps working.

**Who is calling.** Every request carries `Authorization: Bearer <token>`. The token identifies a
rider or a driver. Login is outside this design. "Me" endpoints (`/riders/me`, `/drivers/me`) act on
the caller. The server always takes the caller's identity from the token, never from the request
body, so a rider can't request a ride "as" someone else.

**Response envelope.** Success: `{ "data": ... }`, plus `"meta"` on lists. Error:

```json
{ "error": { "code": "TRIP_ALREADY_TAKEN", "message": "Another driver accepted this trip", "details": [] } }
```

`code` is stable and meant for programs; `message` is for people. `details` lists each invalid
field on a `422`.

**Status codes used everywhere:**

| Status | Code(s)                      | When                                                                             |
| ------ | ---------------------------- | -------------------------------------------------------------------------------- |
| 400    | `INVALID_JSON`, `INVALID_QUERY`, `IDEMPOTENCY_KEY_REQUIRED` | the request itself is malformed                     |
| 401    | `UNAUTHENTICATED`            | no token, or an expired one                                                      |
| 403    | `WRONG_ROLE`                 | a valid token for the wrong kind of user, e.g. a rider calling a driver endpoint |
| 404    | `NOT_FOUND`                  | doesn't exist, **or exists but isn't yours**. Saying "forbidden" would confirm the id is real |
| 409    | depends on endpoint          | the request conflicts with the current state                                     |
| 422    | `VALIDATION_FAILED`          | well-formed but invalid fields; each one is named in `details`                   |
| 429    | `RATE_LIMITED`               | too many requests; `Retry-After` header set                                      |

**Money** is always `...Minor` (an integer in kobo) with `currency` beside it: `"finalFareMinor": 415000, "currency": "NGN"` is ₦4,150.

**Times** are ISO 8601 in UTC: `"2026-09-25T18:19:11Z"`.

**Retrying safely (idempotency).** Mobile networks drop requests. Any request that **creates**
something needs an `Idempotency-Key` header: a unique string the app makes up (a UUID) and reuses
if it retries the *same* request. The server stores the key in a unique column:

- same key, same body → the original result, with `200`
- same key, different body → `409 IDEMPOTENCY_KEY_REUSED`

Status-change requests (accept, arrive, start, complete, cancel) don't need a key. Each one only
changes a trip that is in the expected status, so repeating it finds the trip already changed.
The server then returns the trip as it is, with `200`, if the same caller made the change, and a
`409` if someone else did.

**Lists: pagination, filtering, sorting.** Every list endpoint uses the same contract:

| Parameter | Type    | Default          | Rules                                                          |
| --------- | ------- | ---------------- | -------------------------------------------------------------- |
| `limit`   | integer | 20               | 1 to 100; anything above 100 is treated as 100                 |
| `cursor`  | string  | none (first page) | `meta.nextCursor` from the previous page, unchanged           |
| `sort`    | enum    | per endpoint     | one of the endpoint's listed sort fields, otherwise `400`      |
| `order`   | enum    | per endpoint     | `asc` or `desc`                                                |
| filters   | per endpoint | none        | an unknown parameter is `400`, not silently ignored            |

```json
{ "data": [ ... ], "meta": { "limit": 20, "hasMore": true, "nextCursor": "eyJ2Ijoi..." } }
```

Cursor pagination, because trip history keeps growing while people scroll it. With offset
pagination, a new trip arriving at the top shifts every page down by one, and the rider sees a
trip twice. Lists **don't return a total count**: counting every trip a rider has taken on every
page load costs more than any screen needs. The app only needs "is there more?".

---

## The five key actions

### A1. Request a ride

#### `GET /api/v1/fare-estimates`: see the price before confirming

Rider only. Safe to call any number of times; creates nothing.

| Query parameter | Type   | Required | Rules                        |
| --------------- | ------ | -------- | ---------------------------- |
| `city`          | enum   | yes      | `Lagos`, `Abuja`             |
| `pickupLat`, `pickupLng`   | number | yes | valid coordinates        |
| `dropoffLat`, `dropoffLng` | number | yes | not the same point as pickup |

```json
{ "data": { "fareMinor": 385000, "currency": "NGN", "distanceMetres": 14800, "durationSeconds": 2700 } }
```

Errors: `400` missing or invalid parameter; `422 OUTSIDE_SERVICE_AREA`; `503 MAPS_UNAVAILABLE` (the
route distance comes from an external maps service).

#### `POST /api/v1/trips`: confirm the request

Rider only. **Requires `Idempotency-Key`.**

| Body field       | Type   | Required | Rules                          |
| ---------------- | ------ | -------- | ------------------------------ |
| `city`           | enum   | yes      | `Lagos`, `Abuja`               |
| `pickup`         | object | yes      | `{ "lat": number, "lng": number, "address": string (1-200) }` |
| `dropoff`        | object | yes      | same shape; not the same point as pickup |

The server works out the distance, time, and price itself (the same way as the estimate) and stores
them. The app never sends a price.

**`201 Created`**, with `Location: /api/v1/trips/{id}`. Not `202 Accepted`: the trip exists as soon
as this returns; only finding a driver happens later. Body: the [Trip](#trip) with
`status: "requested"`.

| Error | Code                       | When                                                              |
| ----- | -------------------------- | ----------------------------------------------------------------- |
| 400   | `IDEMPOTENCY_KEY_REQUIRED` | no key                                                            |
| 409   | `RIDER_HAS_ACTIVE_TRIP`    | the rider already has a trip that isn't finished (R1: `trips_one_active_per_rider`) |
| 409   | `IDEMPOTENCY_KEY_REUSED`   | same key, different body                                          |
| 422   | `VALIDATION_FAILED`        | a field is missing or invalid                                     |
| 422   | `OUTSIDE_SERVICE_AREA`     | no current price list for that city                               |
| 503   | `MAPS_UNAVAILABLE`         | couldn't work out the route                                       |

**Idempotent:** yes, by `Idempotency-Key` (stored as `trips.request_key`, unique per rider).
Query: `A1_request_ride`.

### A2. Find and accept a request

#### `GET /api/v1/trip-requests`: open requests near me

Driver only, and only while online.

| Query parameter | Type   | Required | Rules                          |
| --------------- | ------ | -------- | ------------------------------ |
| `lat`, `lng`    | number | yes      | the driver's current position  |
| `radiusMetres`  | integer | no, default 3000 | 500 to 10000          |
| `limit`         | integer | no, default 10   | 1 to 20; no cursor: this is a live view, not a history |

Sorted by `requestedAt` ascending (longest-waiting first). This is fixed, not a `sort` parameter,
so drivers can't pick only the best-paying trips.

```json
{
  "data": [
    {
      "id": "e0d54581-0f96-4ed4-b3f1-1bd0deb45574",
      "pickupAddress": "Yaba Tech main gate, Herbert Macaulay Way",
      "dropoffAddress": "Ikeja City Mall, Obafemi Awolowo Way",
      "distanceToPickupMetres": 850,
      "quotedFareMinor": 385000,
      "currency": "NGN",
      "requestedAt": "2026-09-25T18:19:11Z"
    }
  ],
  "meta": { "limit": 10 }
}
```

Only what a driver needs to decide. No rider name or phone until they accept.

Errors: `400`; `403 WRONG_ROLE`; `409 DRIVER_OFFLINE`. Query: `A2_find_nearby_requests`.

#### `POST /api/v1/trips/{id}/accept`

Driver only. No body.

`200` with the [Trip](#trip), now `accepted`, with the driver and car filled in.

| Error | Code                     | When                                                                       |
| ----- | ------------------------ | -------------------------------------------------------------------------- |
| 404   | `NOT_FOUND`              | no such trip                                                               |
| 409   | `TRIP_ALREADY_TAKEN`     | another driver accepted first (the update matched 0 rows)                  |
| 409   | `TRIP_NOT_OPEN`          | the trip was cancelled                                                     |
| 409   | `DRIVER_HAS_ACTIVE_TRIP` | this driver is already on a trip (R2: `trips_one_active_per_driver`)       |
| 409   | `DRIVER_OFFLINE`         | the driver isn't online, or has no active car                              |

**Idempotent:** yes. If this driver already accepted this trip, it returns `200` with the trip.
Query: `A2_accept`.

### A3. Take the trip through to the end

Three endpoints, one per arrow in the [state machine](3-decisions.md#status-and-state). Separate
endpoints rather than `PATCH { "status": ... }`, because each change needs different data and
different checks (complete needs the distance; arrive doesn't). One endpoint per allowed change
also makes forbidden changes impossible to even ask for.

All three: driver only, and only the trip's own driver (anyone else gets `404`). Each returns
`200` with the [Trip](#trip).

| Endpoint                              | Body                                                               | Moves     | Query         |
| ------------------------------------- | ------------------------------------------------------------------ | --------- | ------------- |
| `POST /api/v1/trips/{id}/arrive`      | none                                                               | `accepted` → `arrived` | `A3_arrive` |
| `POST /api/v1/trips/{id}/start`       | none                                                               | `arrived` → `in_progress` | `A3_start` |
| `POST /api/v1/trips/{id}/complete`    | `actualDistanceMetres` (integer > 0, required), `actualDurationSeconds` (integer > 0, required) | `in_progress` → `completed` | `A3_complete` |

Completing sets `finalFareMinor`, worked out from the real distance and time using the price list
from when the ride was requested (R3).

| Error | Code                | When                                                                               |
| ----- | ------------------- | ---------------------------------------------------------------------------------- |
| 404   | `NOT_FOUND`         | no such trip, or not this driver's                                                 |
| 409   | `INVALID_TRANSITION`| the trip isn't in the status this step needs, e.g. `start` on a trip that's `accepted` (must `arrive` first), or anything on a `cancelled` trip. `details` gives the current status |
| 422   | `VALIDATION_FAILED` | `complete` without a valid distance or duration                                   |

**Idempotent:** yes. Repeating a step that already happened returns `200` and the trip unchanged.
`complete` twice doesn't recalculate the fare.

#### `POST /api/v1/trips/{id}/cancel`

Rider or the trip's driver. Body: `reason` (string, optional, ≤ 200).

| Error | Code                 | When                                                                       |
| ----- | -------------------- | -------------------------------------------------------------------------- |
| 404   | `NOT_FOUND`          | no such trip, or not yours                                                 |
| 409   | `INVALID_TRANSITION` | the trip is `in_progress`, `completed`, or already cancelled by the other side. A trip the rider is in can't be cancelled; it's completed |

**Idempotent:** yes. Cancelling your own already-cancelled trip returns `200`.

### A4. Pay for the trip

#### `POST /api/v1/trips/{id}/payments`

Rider only, the trip's own rider. **Requires `Idempotency-Key`.**

| Body field | Type | Required | Rules         |
| ---------- | ---- | -------- | ------------- |
| `method`   | enum | yes      | `card`, `cash` |

There is **no amount field.** The amount is always the trip's `finalFareMinor`, read by the server.
An app can't pay a different amount even if it tries.

- **Card:** `201` with the [Payment](#payment) in `pending`. The card processor confirms later
  through `POST /api/v1/webhooks/payments` (signature-verified, not called by apps), which moves it
  to `succeeded` or `failed`. The app polls `GET /api/v1/trips/{id}/payments`, or gets a
  `payment_updated` event (see [real-time](#real-time-watching-the-driver-approach)).
- **Cash:** `201` with the payment in `pending`. The driver confirms receiving it with
  `POST /api/v1/trips/{id}/payments/{paymentId}/confirm-cash`, which moves it to `succeeded`.

| Error | Code                     | When                                                                 |
| ----- | ------------------------ | -------------------------------------------------------------------- |
| 400   | `IDEMPOTENCY_KEY_REQUIRED` |                                                                    |
| 404   | `NOT_FOUND`              | no such trip, or not yours                                           |
| 409   | `TRIP_NOT_COMPLETED`     | there's no final fare yet                                            |
| 409   | `ALREADY_PAID`           | the trip already has a pending or successful payment (`payments_one_live_per_trip`) |
| 409   | `IDEMPOTENCY_KEY_REUSED` |                                                                      |
| 422   | `VALIDATION_FAILED`      | unknown method                                                       |

**Idempotent:** yes, by `Idempotency-Key` (`payments_idempotency_key_unique`). The rule that matters
most (R4): a network retry can never charge twice. Queries: `A4_pay`, `A4_confirm`.

#### `GET /api/v1/trips/{id}/payments`

The trip's rider or driver. Every attempt, newest first (at most a handful, so not paginated).

### A5. Look back and rate

#### `GET /api/v1/riders/me/trips`: my trip history

Rider only. Returns [TripSummary](#tripsummary) items, not full trips (see
[over-fetching](#over-fetching-rest-vs-graphql)).

| Query parameter | Type | Default       | Rules                                               |
| --------------- | ---- | ------------- | --------------------------------------------------- |
| `status`        | enum | all           | `completed`, `cancelled`, or `active`               |
| `from`, `to`    | date | none          | `requestedAt` range                                 |
| `sort`          | enum | `requestedAt` | only `requestedAt`                                  |
| `order`         | enum | `desc`        |                                                     |
| `limit`, `cursor` |    |               | see [conventions](#conventions)                     |

Errors: `400`, `401`, `403`. Query: `A5_trip_history`. Drivers have the same list at
`GET /api/v1/drivers/me/trips`, sorted by `completedAt`, which uses `trips_driver_completed`.

#### `POST /api/v1/trips/{id}/ratings`

The trip's rider (rating the driver) or driver (rating the rider). The side is taken from the token.

| Body field | Type    | Required | Rules           |
| ---------- | ------- | -------- | --------------- |
| `score`    | integer | yes      | 1 to 5          |
| `comment`  | string  | no       | up to 500       |

`201` with the [Rating](#rating).

| Error | Code                 | When                                                                   |
| ----- | -------------------- | ---------------------------------------------------------------------- |
| 404   | `NOT_FOUND`          | no such trip, or not yours                                             |
| 409   | `TRIP_NOT_COMPLETED` | `ratings_trip_must_be_completed`                                       |
| 409   | `ALREADY_RATED`      | this side already rated this trip, with a different score (`ratings_once_per_side`) |
| 422   | `VALIDATION_FAILED`  | score outside 1 to 5                                                   |

**Idempotent:** yes, without a key. The unique `(trip, side)` pair is the natural key. Sending the
same score again returns the existing rating with `200`; a different score is `409`, because
scores are final. Query: `A5_rate`.

---

## Other operations per entity

Shorter: same conventions, same errors (`400`, `401`, `403`, `404`, `422`) unless listed.

### Riders

| Method + path                  | Who    | Request                                  | Response            | Idempotent | Extra errors |
| ------------------------------ | ------ | ---------------------------------------- | ------------------- | ---------- | ------------ |
| `GET /api/v1/riders/me`        | rider  | none                                     | [Rider](#rider)     | safe       |              |
| `PATCH /api/v1/riders/me`      | rider  | any of `fullName` (1-100), `email` (email or `null`) | Rider   | yes (setting a value twice is the same) | `409 EMAIL_TAKEN` |
| `DELETE /api/v1/riders/me`     | rider  | none                                     | `204`               | yes (deleting twice is `204`) | `409 RIDER_HAS_ACTIVE_TRIP` |

Deleting sets `deleted_at` and removes name, phone, and email. Trips and payments stay (see
[time and deletion](3-decisions.md#time-and-deletion)). The phone number changes through a
verification flow outside this design.

### Drivers

| Method + path                         | Who     | Request                   | Response                  | Idempotent | Extra errors |
| ------------------------------------- | ------- | ------------------------- | ------------------------- | ---------- | ------------ |
| `GET /api/v1/drivers/me`              | driver  | none                      | [Driver](#driver)         | safe       |              |
| `PUT /api/v1/drivers/me/availability` | driver  | `isOnline` (boolean, required) | Driver               | yes        | `409 NO_ACTIVE_VEHICLE` when going online without a car; `409 DRIVER_HAS_ACTIVE_TRIP` when going offline mid-trip |
| `GET /api/v1/drivers/{id}`            | the rider on a trip with this driver | none | [DriverCard](#drivercard) | safe | `404` for anyone else |
| `DELETE /api/v1/drivers/me`           | driver  | none                      | `204`                     | yes        | `409 DRIVER_HAS_ACTIVE_TRIP` |

### Vehicles

| Method + path                                        | Who    | Request                                                          | Response   | Idempotent | Extra errors |
| ---------------------------------------------------- | ------ | ---------------------------------------------------------------- | ---------- | ---------- | ------------ |
| `GET /api/v1/drivers/me/vehicles`                    | driver | none                                                             | list of [Vehicle](#vehicle), not paginated (a handful per driver) | safe | |
| `POST /api/v1/drivers/me/vehicles`                   | driver | `plateNumber`, `make`, `model`, `colour` (strings, required), `year` (integer 1990 to next year, required); `Idempotency-Key` | `201` Vehicle, not active | yes, by key | `409 PLATE_IN_USE` (`vehicles_plate_in_use`) |
| `POST /api/v1/drivers/me/vehicles/{id}/activate`     | driver | none                                                             | Vehicle    | yes        | `409 DRIVER_HAS_ACTIVE_TRIP` (can't swap cars mid-trip) |
| `DELETE /api/v1/drivers/me/vehicles/{id}`            | driver | none                                                             | `204` (soft delete) | yes | `409 VEHICLE_ACTIVE` (activate another first) |

### Trips (reads)

| Method + path                      | Who                         | Response                                      |
| ---------------------------------- | --------------------------- | --------------------------------------------- |
| `GET /api/v1/trips/{id}`           | the trip's rider or driver  | [Trip](#trip); `404` for anyone else          |
| `GET /api/v1/riders/me/trips/active` | rider                     | the trip that isn't finished, or `404` (uses `trips_one_active_per_rider`) |
| `GET /api/v1/drivers/me/trips/active` | driver                   | same, for the driver                          |

### Fare rules

| Method + path                                   | Who    | Response                                                     |
| ----------------------------------------------- | ------ | ------------------------------------------------------------ |
| `GET /api/v1/fare-rules/current?city=Lagos`     | anyone signed in | [FareRule](#farerule) in force now; `404` if the city isn't served |

Creating price lists is an operations task outside this API. A new list closes the old one
(`fare_rules_no_overlap` stops two overlapping).

### Ratings (reads)

`GET /api/v1/trips/{id}/ratings`: the trip's rider or driver; both ratings if they exist. Ratings
have no update or delete endpoint: scores are final.

---

## Representations

### Trip

```json
{
  "id": "e0d54581-0f96-4ed4-b3f1-1bd0deb45574",
  "status": "completed",
  "city": "Lagos",
  "pickup":  { "lat": 6.5095, "lng": 3.3711, "address": "Yaba Tech main gate, Herbert Macaulay Way" },
  "dropoff": { "lat": 6.6018, "lng": 3.3515, "address": "Ikeja City Mall, Obafemi Awolowo Way" },
  "estimatedDistanceMetres": 14800,
  "estimatedDurationSeconds": 2700,
  "actualDistanceMetres": 15600,
  "actualDurationSeconds": 3120,
  "quotedFareMinor": 385000,
  "finalFareMinor": 415000,
  "currency": "NGN",
  "rider":  { "id": "1a2f8ce3-4d80-4dac-abc8-5a23188cc9f0", "firstName": "Emeka" },
  "driver": { "id": "9c976fb9-eee5-43a4-8ce8-bc53d4002be1", "name": "Uchenna Garba", "ratingAverage": 5.0, "ratingCount": 33 },
  "vehicle": { "plateNumber": "LND 241 HJ", "description": "Blue Toyota Camry" },
  "requestedAt": "2026-09-25T18:19:11Z",
  "acceptedAt":  "2026-09-25T18:20:02Z",
  "arrivedAt":   "2026-09-25T18:27:40Z",
  "startedAt":   "2026-09-25T18:29:15Z",
  "completedAt": "2026-09-25T19:21:15Z",
  "cancelledAt": null,
  "cancelledBy": null,
  "cancelReason": null,
  "payment": { "status": "succeeded", "method": "card" },
  "myRating": 5
}
```

`driver.name` and `vehicle` come from the trip's snapshots, so they show the driver and car as
they were on the day (R6). The rider sees the driver's name; the driver only sees the rider's first
name. Phone numbers are never shared; calls would go through a masked number, outside this design.

### TripSummary

What a list row needs, and nothing else:

```json
{
  "id": "e0d54581-0f96-4ed4-b3f1-1bd0deb45574",
  "status": "completed",
  "requestedAt": "2026-09-25T18:19:11Z",
  "pickupAddress": "Yaba Tech main gate, Herbert Macaulay Way",
  "dropoffAddress": "Ikeja City Mall, Obafemi Awolowo Way",
  "fareMinor": 415000,
  "currency": "NGN",
  "driverName": "Uchenna Garba",
  "myRating": 5
}
```

`fareMinor` is the final fare, or the quoted fare while the trip isn't finished.

### Payment

```json
{ "id": "a13284e2-34af-4102-9622-a23bc1625692", "tripId": "e0d54581-...", "amountMinor": 415000, "currency": "NGN",
  "method": "card", "status": "succeeded", "failureReason": null, "createdAt": "2026-09-25T19:21:40Z" }
```

`provider_reference` is internal and never returned.

### Rating

```json
{ "id": "3dc6249c-acfe-4973-b89d-28ed0873138b", "tripId": "e0d54581-...", "raterRole": "rider", "score": 5,
  "comment": "Smooth ride, AC was working", "createdAt": "2026-09-25T19:25:00Z" }
```

### Rider

`{ "id", "fullName", "phone", "email", "ratingAverage", "ratingCount", "createdAt" }`: only ever returned to the rider themselves.

### Driver

`{ "id", "fullName", "phone", "licenceNumber", "isOnline", "ratingAverage", "ratingCount", "activeVehicle": Vehicle, "createdAt" }`: only to the driver themselves.

### DriverCard

`{ "id", "name", "ratingAverage", "ratingCount", "vehicle": { "plateNumber", "description" } }`: what a rider may see about their driver.

### Vehicle

`{ "id", "plateNumber", "make", "model", "colour", "year", "isActive", "createdAt" }`

### FareRule

`{ "id", "city", "currency", "baseFareMinor", "perKmMinor", "perMinuteMinor", "minimumFareMinor", "effectiveFrom", "effectiveTo" }`

`ratingAverage` is `rating_sum / rating_count` rounded to 2 decimal places for display only, or
`null` with no ratings. It is worked out when responding; it's never stored.

---

## Over-fetching: REST vs GraphQL

**The endpoint.** The rider's trip history screen shows, per row: the date, where from, where to,
the price, and the status. Five things.

If the history endpoint returned full [Trip](#trip) objects, each row would carry about 30 fields:
coordinates, every timestamp, estimated and actual distance and duration, both fares, the driver's
rating, the car, payment status. The example Trip below is about 1.1 KB, so a page of 20 is roughly
22 KB on a phone that may be on a slow 3G connection in traffic, of which the screen uses roughly a
quarter.

**The same need in GraphQL:**

```graphql
query TripHistory {
  me {
    trips(first: 20) {
      edges {
        node { id requestedAt pickupAddress dropoffAddress finalFareMinor currency status }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
```

which returns only those fields:

```json
{
  "data": {
    "me": {
      "trips": {
        "edges": [
          { "node": { "id": "e0d54581-...", "requestedAt": "2026-09-25T18:19:11Z",
                      "pickupAddress": "Yaba Tech main gate, Herbert Macaulay Way",
                      "dropoffAddress": "Ikeja City Mall, Obafemi Awolowo Way",
                      "finalFareMinor": 415000, "currency": "NGN", "status": "completed" } }
        ],
        "pageInfo": { "hasNextPage": true, "endCursor": "eyJ2Ijoi..." }
      }
    }
  }
}
```

**Would I use GraphQL here? No, not for this product at this stage.** REST is the right default for
an MVP: every endpoint is simple to cache, rate-limit, log, and secure one at a time. GraphQL would
bring a schema layer, query cost limits (a nested query can ask for far more than any REST endpoint
would allow), and harder caching.

And **this over-fetching problem has a REST fix that's already in the design**: the list endpoint
returns a smaller [TripSummary](#tripsummary), and the full [Trip](#trip) is only returned by
`GET /trips/{id}` when someone opens one trip. That removes most of the waste with no new
technology.

**When I would switch.** Not at a number of users. Ten million users all on the same two screens
is still a REST problem. The trigger is the **number of different clients that need different
shapes of the same data**. Today there are two (rider app, driver app). If an operations dashboard,
a business-travel portal, and a partner API each started needing their own version of the trip,
we'd be adding a new summary shape or `?fields=` option for each one. At about the third or fourth
client doing that, one GraphQL layer beats a growing pile of special-case endpoints. The other
trigger is measurement: if payload size showed up as a real cost on slow networks after the
summary fix, that would push the same way.

---

## Real-time: watching the driver approach

**Where.** After a driver accepts, the rider watches the car move towards them on a map, sees
"Driver has arrived", and later "Payment received". Polling `GET /trips/{id}` every few seconds
would be slow to update and would multiply requests by every waiting rider.

**Rider app: Server-Sent Events.** `GET /api/v1/trips/{id}/events` returns a `text/event-stream`
that stays open:

```
event: driver_location
data: {"lat": 6.5121, "lng": 3.3702, "etaSeconds": 240}

event: status_changed
data: {"status": "arrived", "at": "2026-09-25T18:27:40Z"}
```

The rider only **receives** here. Everything the rider does (cancel, pay, rate) is a normal
`POST`. Traffic is one-way, server to client, which is exactly what SSE is: plain HTTP, so it
goes through the same authentication, load balancers, and proxies as the rest of the API. It also
reconnects by itself after a network drop (the browser/client sends `Last-Event-ID`), which
matters on mobile networks.

**Driver app: WebSocket.** The driver's app **sends** its location every few seconds, and
**receives** new trip offers and cancellations, both at once, all the time it's online. That's
two-way traffic on one long-lived connection, which is what WebSockets are for. Using SSE plus a
`POST` every 3 seconds per online driver would work, but it would be far more requests for the
busiest traffic in the system.

So the choice follows the direction of traffic: **one-way → SSE, two-way → WebSocket.**

**What's stored.** Location updates are not written to Postgres: thousands of drivers, every few
seconds, is a lot of writes, and each update is useless a few seconds later. They'd live in memory
(e.g. Redis) and be sent on. Only what matters for the record goes into `trips`: the times of each
status change and the final distance.
