# Price adjustment check

Are the VCI prices in `stg.stg_price_daily` adjusted for corporate actions, and is any corporate
action left unadjusted? Checked with `sql/04_quality/110_stg_price_adjustment_checks.sql`
on 10 tickers x 497 sessions (2024-09-26 to 2026-09-25). First run 2026-09-30.

## Method

- **Tick grid.** HOSE quotes in steps of 0.01 / 0.05 / 0.1 thousand VND (below 10 / 10 to 49.95 /
  50 and up). An unadjusted close sits on that grid. When VCI adjusts history for a corporate action
  it multiplies the older prices by a factor and rounds to 2 decimals, so most of them fall off the grid.
  The last off-grid date shows roughly where the latest adjustment happened.
- **Limits of the test.**
  - Below 10 the tick equals the stored precision (2 decimals), so every price is on the grid.
    The test says nothing for those sessions.
  - An adjusted price lands on the grid by chance about 1 time in 5 (tick 0.05) or 1 in 10
    (tick 0.1). A fully adjusted stretch shows roughly 80-90% off grid, not 100%.
  - 0% off grid means the series was never multiplied in the window. That points to no corporate
    action in the window, not to bad data.
- **±7% band.** A daily move above 7% and up to 7.5% is a ceiling or floor session after rounding.
  Above 7.5% would point to a corporate action VCI didn't adjust for. The band only catches large
  events: an unadjusted cash dividend of 500-1,000 VND is a 1-3% drop and never crosses 7%.
  That is why the ex-date cross-check below is needed.

## Result: off-grid share per ticker (query 1)

| ticker | off grid | % of 497 | first off grid | last off grid |
|---|---|---|---|---|
| ACB | 325 | 65.4 | 2024-09-26 | 2026-06-12 |
| CTG | 368 | 74.0 | 2024-09-26 | 2026-07-21 |
| HDB | 252 | 50.7 | 2024-09-26 | 2025-12-15 |
| MBB | 378 | 76.1 | 2024-09-26 | 2026-08-07 |
| SHB | 216 | 43.5 | 2025-03-24 | 2026-04-02 |
| STB | 0 | 0.0 | - | - |
| TCB | 322 | 64.8 | 2024-09-26 | 2026-05-13 |
| TPB | 221 | 44.5 | 2024-09-26 | 2025-10-29 |
| VCB | 394 | 79.3 | 2024-09-26 | 2026-07-22 |
| VPB | 413 | 83.1 | 2024-09-26 | 2026-09-23 |

- 9 tickers are adjusted: off grid from the start of the window up to a last date, on grid after it.
- STB: 0 off grid in 497 sessions. Its closes run 31.95 to 78.20, all above 10, so the test applies
  to every session. STB has no dividend, bonus share or rights disclosure in the window (query 6:
  only meetings, votes and board nominations), so there was nothing to adjust.
- SHB: 125 sessions close below 10, the last on 2025-04-10 (min close 7.65). The test is blind there.
  First off grid 2025-03-24 is where the price starts to cross 10, not where adjustment starts.
  Over the 372 sessions at 10 or above, 216 are off grid (58%).
- Every other ticker stays above 10 for the whole window (lowest min close: TPB 10.39).

## Result: cash dividend, VCB and CTG ex-date 2026-07-23, 450 VND (query 3)

Period 2026-06-01 to 2026-09-25: 38 sessions before 2026-07-23, 44 from it.

| ticker | off grid before | off grid from |
|---|---|---|
| VCB | 36 / 38 | 0 / 44 |
| CTG | 35 / 38 | 0 / 44 |

Both switch from off grid to on grid at the ex-date of a cash-only dividend. VCI adjusts history
for cash dividends. This answers the open question from the project scope: returns built on these
prices already include the dividend, and high-dividend tickers are not understated by it.

## Result: moves beyond ±7% (queries 4 and 5)

| ticker | date | prev close | close | return |
|---|---|---|---|---|
| HDB | 2025-12-16 | 23.13 | 24.75 | +7.00% |
| MBB | 2025-08-14 | 20.66 | 22.11 | +7.02% |
| SHB | 2025-03-14 | 8.40 | 8.99 | +7.02% |
| TPB | 2025-07-29 | 15.67 | 14.57 | -7.02% |
| VPB | 2025-08-22 | 30.13 | 28.02 | -7.00% |

All 5 are within 7.5% (ceiling or floor sessions; the prev close is itself an adjusted, rounded
value, which is how a ceiling session can show slightly more than 7%). None beyond 7.5% for any ticker.

## Cross-check with ex-dates (queries 6 to 8)

Query 6 reads the ex-date (ngày GDKHQ) from the CafeF disclosure titles in raw.raw_ticker_news,
format `VCB: 23.7.2026, ngày GDKHQ ...`. Query 7 compares each ticker's latest price event in the
window with its last off-grid close. Query 8 lists the 5 closes before that ex-date.

Result, query 6: every GDKHQ title parses to a date. 25 price events fall in the window
(ACB 2, CTG 3, HDB 2, MBB 4, SHB 4, STB 0, TCB 2, TPB 2, VCB 3, VPB 3). All rows flagged
price_event = 0 are meetings, written votes or board nominations; none of them moves the price.

Result, query 7 (latest price event in the window per ticker):

| ticker | last ex-date | session before ex | last off grid | on-grid gap | off grid from ex |
|---|---|---|---|---|---|
| ACB | 2026-06-15 | 2026-06-12 | 2026-06-12 | 0 | 0 |
| CTG | 2026-07-23 | 2026-07-22 | 2026-07-21 | 1 | 0 |
| HDB | 2025-12-18 | 2025-12-17 | 2025-12-15 | 2 | 0 |
| MBB | 2026-08-11 | 2026-08-10 | 2026-08-07 | 1 | 0 |
| SHB | 2026-04-03 | 2026-04-02 | 2026-04-02 | 0 | 0 |
| STB | - | - | - | - | - |
| TCB | 2026-05-19 | 2026-05-18 | 2026-05-13 | 3 | 0 |
| TPB | 2025-10-30 | 2025-10-29 | 2025-10-29 | 0 | 0 |
| VCB | 2026-07-23 | 2026-07-22 | 2026-07-22 | 0 | 0 |
| VPB | 2026-09-24 | 2026-09-23 | 2026-09-23 | 0 | 0 |

- For all 9 tickers with an event, the last off-grid close is on or before the session before the
  ex-date, and nothing is off grid from the ex-date on. Every adjustment lines up with a disclosed
  event; no adjustment without a disclosure.
- Latest events by type: cash only (CTG, TCB, VCB), share dividend or bonus (HDB, TPB, VPB),
  cash + shares (ACB), shares + rights offering (MBB), rights offering (SHB). VCI adjusts all of them.
- On-grid gap: a few closes just before the ex-date sit on the grid. Query 8 checks why:
  - Cash dividend D: the adjusted close is about close x (1 - D / last close before ex), so a close
    within about 0.005 / D of the last close shifts by almost exactly D. If D is a multiple of the
    tick, it stays on the grid. CTG: D = 0.45, tick 0.05, gap 1. VCB: D = 0.45, tick 0.1, gap 0.
  - Share events (HDB, MBB): the factor is far from 1, so the gap is chance (about 1 in 5 per session
    at tick 0.05).

Result, query 8 (5 closes before the latest ex-date; pct = distance from the close before ex):

- TCB, cash 0.70, tick 0.05. The close stays on the grid when |pct| < 0.005 / 0.70 = 0.71%.

  | date | close | pct | off grid |
  |---|---|---|---|
  | 2026-05-12 | 33.10 | -0.60 | 0 |
  | 2026-05-13 | 32.91 | -1.17 | 1 |
  | 2026-05-14 | 33.30 | 0.00 | 0 |
  | 2026-05-15 | 33.35 | 0.15 | 0 |
  | 2026-05-18 | 33.30 | 0.00 | 0 |

  All 5 rows follow the rule, including 05-12 (inside 0.71%, on grid) and 05-13 (outside, off grid).
  The gap of 3 is rounding, not missing adjustment.
- CTG, cash 0.45, tick 0.05 (limit 1.11%): only 07-22 is within it and on grid; 07-16 to 07-21 are
  3.7% to 8.8% away and off grid.
- VCB, cash 0.45, tick 0.1: 0.45 is not a multiple of 0.1, so even 07-22 is off grid.
- Adding D back to the close before ex gives an on-grid price in all three cases:
  TCB 33.30 + 0.70 = 34.00, CTG 29.25 + 0.45 = 29.70, VCB 54.05 + 0.45 = 54.50.
- HDB (shares 100:25 + bonus 100:4.69) and MBB (shares 100:15 + rights 10:1): the factor is far
  from 1, so an on-grid close before ex is chance. HDB's two on-grid closes are the same value
  (24.75 on 12-16 and 12-17).
- Several consecutive closes repeat exactly: ACB 22.83 on 4 sessions (2026-06-09 to 06-12),
  VCB 56.23 on 07-20 and 07-21, HDB 24.75 on 2025-12-16 and 12-17. See next section.

## Repeated closes (`100_stg_price_checks.sql` queries 7 and 8)

Question: are repeated closes real sessions, or rows the source copied forward?

- Query 7: same close as the previous session per ticker: ACB 68, CTG 29, HDB 51, MBB 36, SHB 79,
  STB 27, TCB 37, TPB 58, VCB 43, VPB 52 (out of 496 pairs). same_bar (open, high, low, close
  and volume all equal to the previous session) = 0 for every ticker.
- Query 8: 50 runs of 3 or more sessions with the same close, the longest 5 (SHB 8.40 on
  2025-03-05 to 03-11, VPB 14.46 on 2024-11-22 to 11-28). In every run each session has its own
  volume; open/high/low differ in all but a few sessions.
- ACB 2026-06-09 to 06-12: close 22.83 four times, volumes 48.8M, 38.0M, 23.6M, 61.2M, different
  open/high/low each day.
- Conclusion: real trading sessions that closed at the same price. Kept as they are, no flag.
  The zero returns they produce are real.
- The share of repeats is higher for tickers whose tick is large compared with the price
  (SHB, ACB, TPB) and lower for STB and CTG. A same-price close is more likely when one tick
  is a bigger step relative to the daily move.
