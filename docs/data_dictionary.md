# Data dictionary

This document describes the tables and views in Banking Sector Intelligence: grain, keys and the
meaning of the main columns. The `dw` and `dq` tables are listed column by column with their types;
the `mart` views are described by what they compute; `raw` and `stg` are summarised at the end.

The database `BankingSectorIntelligence` runs on SQL Server 2025 Express. It covers the period from
26 September 2024 to 25 September 2026 (`config/scope.yaml`): 497 trading sessions for 10 bank
tickers.

| schema | contents | written by |
|---|---|---|
| `raw` | Source data as imported from files, all values kept as text. | Python (`ingest/`), Phase 1 only |
| `stg` | Source data converted to typed tables, de-duplicated and limited to the project window. | `sql/02_load` |
| `dw` | The star schema: date, ticker and article dimensions; price and news fact tables. | procedures in `sql/03_transform` |
| `mart` | Analysis views (600-710) and the views Power BI reads (800-860). | views in `sql/03_transform` |
| `dq` | Results of the data quality checks, one row per check per run. | `dq.sp_run_checks` |

Conventions:
- `ticker` (e.g. VCB) is the durable key of a bank: it stays the same when the bank changes its name.
  `ticker_key` is the surrogate key of one version of a bank in `dim_ticker` (see below). STB has two
  `ticker_key` values and one `ticker`.
- Window functions partition by `ticker` and order by `session_seq`, so a series is not cut at a
  name change and "N sessions" means N trading sessions.
- Technical timestamps are UTC and end in `_utc`.

---

## dw - star schema

### dw.dim_date
Grain: one row per calendar day in the window, trading or not (730 rows). Power BI uses it as the
date table; trading sessions are selected with `is_trading_day`, not by leaving days out.

| column | type | meaning |
|---|---|---|
| date_key | int, PK | yyyymmdd |
| full_date | date, unique | the day; Power BI date table column |
| year | smallint | calendar year |
| quarter, month | tinyint | 1-4, 1-12 |
| month_start | date | first day of the month |
| day_of_month | tinyint | 1-31 |
| iso_week | tinyint | ISO 8601 week number |
| day_of_week | tinyint | 1 = Monday ... 7 = Sunday, independent of SET DATEFIRST |
| is_weekend | bit | Saturday or Sunday |
| is_trading_day | bit | the day is a VNINDEX session (`stg.stg_calendar`) |
| session_seq | smallint | 1..497 over trading days only, NULL on other days; "N sessions before" is session_seq - N |

### dw.dim_ticker (SCD Type 2)
SCD Type 2 keeps every version of a bank's details over time. When a bank's name changes, the
previous record gets a `valid_to` date and a new record is added with a new `ticker_key`. The
ticker itself stays the same.
Grain: one row per version (10 tickers, 11 rows: STB changed its name on 2026-06-01).

| column | type | meaning |
|---|---|---|
| ticker_key | int identity, PK | surrogate key; a new version gets a new key |
| ticker | nvarchar(10) | durable key, e.g. VCB |
| full_name | nvarchar(200) | bank name in this version |
| exchange | nvarchar(10) | HOSE |
| valid_from, valid_to | date | inclusive; first version from 1900-01-01, current one to 9999-12-31 |
| is_current | bit | 1 for the current version; unique per ticker. Use is_current = 1 for today's details, and valid_from / valid_to for the version on a given date. |

### dw.dim_article (Type 1)
Type 1: a changed value overwrites the old one; no history is kept.
Grain: one row per news item (CafeF article or company disclosure).

| column | type | meaning |
|---|---|---|
| article_key | int identity, PK | |
| url | varchar(400), unique | natural key |
| item_type | varchar(10) | `article` (sitemap) or `disclosure` (per-ticker list) |
| article_id | varchar(20), NULL | CafeF id of an article (not unique); NULL for disclosures |
| id_url_count | smallint, NULL | how many URLs share the article_id; NULL for disclosures |
| title | nvarchar(1000) | sitemap title (article) or list title (disclosure) |
| og_title | nvarchar(1000), NULL | page title when the page was fetched |
| publish_time_local | datetime2(0) | Vietnam time |
| time_source | varchar(10) | `page`, `lastmod` or `list` |
| has_time | bit | 0 = date only (disclosures listed at 00:00) |
| page_fetched | bit | the article page was downloaded (always 0 for disclosures) |

### dw.fact_price_daily (periodic snapshot)
A periodic snapshot records a state at regular intervals: here, the price of each ticker on each
trading session.
Grain: one row per ticker per trading session (4,970 rows).

| column | type | meaning |
|---|---|---|
| ticker_key | int, PK part, FK | version valid on the session |
| date_key | int, PK part, FK | trading day |
| open_price, high_price, low_price, close_price | decimal(18,4) | thousand VND, adjusted by VCI; not additive |
| volume | bigint | shares; additive |

### dw.fact_news (factless fact)
A factless fact table records that things are linked and has no measure of its own: here, which
news item is tied to which bank. Counts come from counting rows.
Grain: one row per news item per bank (of the 10) the item is tied to (6,849 rows).

`dim_date` is used twice, for two different purposes (a role-playing dimension):
`publish_date_key` is the day the item was published; `reaction_date_key` is the first trading
session whose price could react to it, and is the date used to match news with price moves.

| column | type | meaning |
|---|---|---|
| article_key | int, PK part, FK | |
| ticker_key | int, PK part, FK | version valid on the publish date |
| publish_date_key | int, FK to dim_date | day the item was published |
| reaction_date_key | int, FK to dim_date, NULL | First trading session that could reflect the news. For news published before 14:45 (end of the closing auction) on a trading day, this is the same day; otherwise, it is the next session. Date-only disclosures are assigned to the next session. NULL if the next eligible session falls outside the project window. |
| match_tier | tinyint | 0 disclosure from the bank's own list, 1 ticker in the title, 2 bank name or strong alias in the title, 3 weak alias + banking context word (rule in place, no alias in this tier) |
| banks_mentioned | smallint | banks named in the item, counting banks outside the 10 |
| is_sector_news | bit, computed | banks_mentioned >= 3; flagged, never deleted |

### dw.price_revision_log
Grain: one row per session whose staged prices differ from the fact when a load runs (VCI restates
history).

| column | type | meaning |
|---|---|---|
| revision_id | bigint identity, PK | |
| run_at_utc | datetime2(0) | time the revision was recorded |
| ticker | nvarchar(10) | durable key of the bank |
| trade_date | date | trading session affected by the revision |
| old_open, old_high, old_low, old_close | decimal(18,4) | prices in the fact before the load |
| new_open, new_high, new_low, new_close | decimal(18,4) | revised prices from staging |
| old_volume, new_volume | bigint | volume before and after the revision |

---

## mart - analysis views
All views: one row per ticker per session unless stated; trading days only.

| view | meaning |
|---|---|
| 600 v_price_session | Closing price of each ticker on each trading session, with `session_seq`. |
| 610 v_return_daily | Daily return of each ticker: `ret` = close / previous session's close - 1. NULL on session 1, or when the previous session is missing. |
| 620 v_sector_return | One row per session. `sector_ret` is the average daily return of the 10 tickers, calculated only when all 10 returns are available. |
| 630 v_sector_index | One row per session. Compounds `sector_ret` into `sector_index`, starting at 100 on the base date. |
| 640 v_ticker_index | Compounds each ticker's daily return into `ticker_index`, starting at 100 on the base date. |
| 650 v_relative_strength | How a ticker does against the sector. `excess_ret` = ticker return - sector return on the same session; `rs` = 100 x ticker_index / sector_index (above 100: ahead of the sector since the base date). |
| 660 v_rolling_corr | `corr_60` measures the correlation between a ticker's daily return and the sector return over a rolling 60-session window, including the current session. It remains NULL until 60 valid pairs are available (first value at session 61). |
| 670 v_excess_zscore | `z` measures how unusual a session's excess return is compared with the 60 sessions before it; the current session is not part of its own window. NULL until 60 valid excess returns are available (first value at session 62). |
| 680 v_excess_iqr | The same comparison with quartiles instead of mean and standard deviation: `out_1_5` and `out_3` flag an excess return outside the 1.5 or 3 IQR fences of the previous 60 sessions. Same availability as 670. |
| 700 v_alert_episode | One row per alert episode: consecutive sessions of one ticker with \|z\| >= 3 in the same direction. `peak_z` is the signed z-score with the largest absolute value; `sum_excess_ret` is the sum of daily excess returns over the episode. |
| 710 v_episode_news | News around each episode: one row per episode and news item (not flagged sector-wide) whose reaction session is within 2 sessions of the episode (from start_seq - 2 through end_seq + 2, inclusive). `position` compares the reaction session with the episode: before = earlier than its first session, during = from its first to its last session, after = later than its last session. `offset_from_start` = reaction session - first session of the episode (-2 = two sessions before it starts). An episode without news keeps one row with NULLs. |

Index values are not returns: an index of 120 represents a 20% increase from its base value of 100.

## mart - Power BI views
The report reads only these views; no table is imported directly.

| view | grain | key | notes |
|---|---|---|---|
| 800 v_pbi_date | calendar day | date_key | all dim_date columns |
| 810 v_pbi_ticker | ticker | ticker | current dim_ticker version: ticker, full_name, exchange |
| 820 v_pbi_sector_session | session | date_key | session_seq, sector_ret, sector_index |
| 830 v_pbi_episode | episode | episode_key = ticker \| start_seq | Columns from `v_alert_episode`, plus `episode_key` and the news_before / during / after counts. |
| 840 v_pbi_ticker_session | ticker x session | (ticker, session_seq) | close_price, ret, sector_ret, excess_ret, ticker_index, rs, corr_60, z, out_3, episode_key, is_alert: 1 when \|z\| >= 3, 0 otherwise; NULL when z is NULL |
| 850 v_pbi_episode_news | episode x news item | (episode_key, article_key) | position, offset_from_start, title, url, publish time, match_tier, item_type; one row with NULL article for an episode without news |
| 860 v_pbi_news | news item x ticker | (article_key, ticker) | publish / reaction date keys, match_tier, is_sector_news, item_type, title, url |

Power BI adds one calculated table, `Index Series` (one row "Sector Index" plus one per ticker, no
relationships), used only by the index chart (decisions 2026-10-20).

---

## dq - data quality history

### dq.dq_run
Grain: one row per run of `dq.sp_run_checks`.

| column | type | meaning |
|---|---|---|
| run_id | int identity, PK | |
| started_at_utc | datetime2(0) | |
| finished_at_utc | datetime2(0), NULL | NULL if the run stopped before the end |
| run_by | sysname | login that ran the checks |
| run_status | varchar(10) | running / completed / failed |

### dq.dq_check_result
Grain: one row per check per run. PK (run_id, check_name).

| column | type | meaning |
|---|---|---|
| run_id | int, PK part, FK to dq_run | |
| check_name | varchar(100), PK part | |
| layer | varchar(10) | raw / stg / dw / mart |
| severity | varchar(5) | ERROR or WARN |
| checked_count | int, NULL | rows the check looked at |
| failed_count | int | rows that failed |
| check_status | varchar(5), computed, persisted | PASS when failed_count = 0, otherwise the severity |
| sample_keys | nvarchar(400), NULL | up to 5 failing keys |
| description | nvarchar(400) | what the check tests |
| checked_at_utc | datetime2(0) | |

---

## raw and stg (short)

| table | grain |
|---|---|
| raw.raw_price_daily, raw.raw_calendar | as in the parquet snapshots, text |
| raw.raw_ticker_news | one row per item of CafeF's per-ticker list |
| raw.raw_article, raw.raw_article_page | one row per sitemap entry; one per fetched page |
| raw.raw_lastmod_sample | 50-article lastmod vs publish-time sample |
| raw.raw_scope, raw.raw_ticker_config, raw.raw_ticker_name_history, raw.raw_alias | config snapshots |
| raw.raw_precision_label | hand-labelled precision sample (`docs/precision_sample.csv`) |
| stg.stg_scope, stg.stg_calendar, stg.stg_price_daily | window; VNINDEX sessions; one row per ticker per session |
| stg.stg_article, stg.stg_ticker_news | one row per sitemap URL; one per ticker per list item |
| stg.stg_bank, stg.stg_alias, stg.stg_alias_context, stg.stg_alias_exclusion | alias rules |
| stg.stg_article_bank_match | one row per article per bank named in its title |
| stg.stg_precision_label | one row per labelled item-bank pair |
