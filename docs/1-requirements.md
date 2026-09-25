# 1. Requirements

## What the product does

A ride-hailing service for Lagos and Abuja. A rider asks for a ride from one place to another and
is told the price up front. A nearby driver accepts, picks the rider up, and drives them there.
The rider pays by card or cash, and each side can rate the other.

## Who uses it

- **Riders**: people who need a ride. They use the rider app.
- **Drivers**: people who own or drive a registered car and give rides. They use the driver app.

Support staff and an operations dashboard exist in a real company, but they are outside this design.

## The five most important actions

Every table, rule, index, and endpoint in this design traces back to one of these. Later
documents refer to them by their number, e.g. "(A2)".

| #      | Who    | Action                                                                                          |
| ------ | ------ | ----------------------------------------------------------------------------------------------- |
| **A1** | Rider  | **Request a ride**: give pickup and dropoff, see the quoted price, confirm.                     |
| **A2** | Driver | **Find and accept a request**: see open requests near them and accept one.                      |
| **A3** | Driver | **Take the trip through to the end**: mark arrived, start the trip, complete it at the dropoff. |
| **A4** | Rider  | **Pay for the trip**: by card or cash, exactly once.                                            |
| **A5** | Rider  | **Look back and rate**: see past trips and rate the driver of a finished one.                   |

Drivers can also rate riders after a trip (part of A5).

## Rules the business depends on

These come from how the service must behave, not from any screen.

| #      | Rule                                                                                          | Why                                                             |
| ------ | --------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| **R1** | A rider can have at most one ride in progress at a time.                                      | Two drivers sent to one person wastes both drivers' time.       |
| **R2** | A driver can have at most one ride in progress at a time.                                     | One car can't be in two places.                                 |
| **R3** | The price the rider saw when requesting is the price the fare was worked out from, even if prices change later. | The rider agreed to that price.                   |
| **R4** | A trip is paid exactly once, for exactly its final fare.                                      | Charging twice, or the wrong amount, is the fastest way to lose riders and invite disputes. |
| **R5** | Only a finished trip can be rated, and only once by each side.                                | A rating for a ride that never happened is fake.                |
| **R6** | The trip record shows who drove and which car, as it was on the day.                          | Receipts, lost property, and safety complaints all depend on it. |
| **R7** | Trip and payment records are kept even if the rider or driver deletes their account. Their personal details are removed. | Money records must be kept for tax and audit; personal data must go when asked. |
| **R8** | Every amount of money is exact.                                                               | Rounding errors on thousands of fares add up to real money.     |

## Not in this design

Surge pricing, scheduled rides, shared rides, promo codes, tips, in-app chat, multiple stops,
cancellation fees, driver document checks, and the support dashboard. Each would add tables and
states without changing the core that A1 to A5 depend on.
