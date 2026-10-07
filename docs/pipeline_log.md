# Pipeline log

What was run, in what order, and what came out. Numbers are from the actual runs.
Decisions and their reasons are in `decisions.md`; details on the news source are in
`news_source_survey.md`. Times are UTC unless marked otherwise.

All Python runs from the repo root in the conda env `bsi`. SQL files run in SSMS.

---

## Phase 0 - Setup (2026-09-27)

### 0.1 Config
- `config/scope.yaml`: window 2024-09-26 to 2026-09-25. End date checked as the last completed
  HOSE session on 2026-09-27 (Vietstock showed 25/09/2026 "Kết thúc phiên").
- `config/tickers.yaml`: 10 tickers, full names checked against Vietstock company pages.
  STB changed its name inside the window (Sài Gòn Thương Tín -> Sài Gòn Tài Lộc, from 2026-06-01,
  SBV Decision 36/QĐ-QLGS4). Stored under `name_history`.

### 0.2 Database
- Run: `sql/01_ddl/000_create_database.sql`, `001_create_schemas.sql`
- Checked with: `sql/04_quality/000_phase0_checks.sql`
- Result: SQL Server 2025 Express 17.0.1000.7. Database `BankingSectorIntelligence`,
  collation `Vietnamese_100_CI_AS`, recovery SIMPLE, schemas raw / stg / dw / mart.
  Server collation is `Latin1_General_CI_AS`.
- Issue: the database already existed with the server default collation and the first
  create script skipped it without a word. Dropped with `900_reset_database.sql` and rebuilt.
  `000` now THROWs when the collation doesn't match.

### 0.3 Repo
- Private GitHub repo, first commit c790b13. `raw/news/`, `config/db.yaml`, `.vs/`, `*.slnx`
  are git-ignored.

---

## Phase 1 - Download and load raw data (2026-09-27 to 2026-09-29)

### 1.1 Environment
- conda env `bsi`, Python 3.12.
- vnstock is quarantined on PyPI. Installed from the vendor index:
  `pip install --extra-index-url https://vnstocks.com/api/simple vnstock vnai`
  -> vnstock 4.0.9, vnai 2.6.2. Licence: personal use, no right to redistribute source data.
- `requirements.txt`: the extra index URL plus 9 pinned direct dependencies.
  Checked with `pip install -r requirements.txt` (all "already satisfied").
- `config/db.yaml` values must be quoted (`"yes"`), PyYAML reads a bare yes as True.
- `python ingest/db.py` -> connected as <machine>\<user>, collation Vietnamese_100_CI_AS.

### 1.2 vnstock behaviour (measured before downloading)
Checked with `inspect.signature` / `inspect.getsource` on the installed package and small calls on VCB:
- `Market().equity(symbol).ohlcv(start, end, interval, count=100, source='kbs')`
- `start` is ignored: asking for 2026-09-01..2026-09-25 returned 100 rows from 2026-05-06.
- `end` is respected and inclusive.
- Default source is `kbs`. `vci` and `kbs` return different adjusted prices and a slightly
  different session list, so the source is always passed explicitly.
- Prices are in thousand VND.
- Guest limit is 20 requests/min and one `ohlcv()` call uses about 2 requests.

### 1.3 Prices and calendar
- Run: `python ingest/download_prices.py` (source=vci, count=600, end from scope.yaml)
- Result: 10 tickers saved to `raw/prices/*.parquet` at 2026-09-27 07:26:00. The first run hit
  the rate limit before VNINDEX; the script was changed to resume without overwriting and to
  sleep 7 s. VNINDEX saved to `raw/calendar/VNINDEX.parquet` at 09:58:12, same day, no trading
  session in between.
- All 11 files: 600 rows, 2024-05-02 -> 2026-09-25.
- Committed right away: 5fea7ed (prices), d28dfea (calendar).
- `base_date` = 2024-09-26, the first VNINDEX session on or after the window start.

### 1.4 Raw price tables
- Run: `sql/01_ddl/010_raw_price_tables.sql`, then `python ingest/load_prices.py`
- Checked with: `sql/04_quality/010_raw_price_checks.sql`
- Result: `raw.raw_price_daily` 6,000 rows (10 x 600), `raw.raw_calendar` 600 rows.
  No duplicates on (symbol, time), no NULL or 'nan' values.
- Rerun check: after a second load the count stayed 6,000 and every row had the new
  `loaded_at_utc` (11:20:57 -> 11:23:11), so the load replaces instead of appending.
- Issue: the price tables were emptied at least once by running the DDL file again
  (tables re-created 2026-09-28 10:01:34 local, 50 s before another table). Found when the
  lastmod analysis returned only NULL sessions. The raw DDL now uses create-if-missing and
  `901_drop_raw_tables.sql` is the only way to drop.

### 1.5 News source survey
- robots.txt, sitemap structure, per-ticker endpoint, lastmod vs publish time on 2 articles.
- Written up in `news_source_survey.md`.

### 1.6 Per-ticker news list
- Run: `python ingest/crawl_ticker_news.py`
  (endpoint `/du-lieu/Ajax/Events_RelatedNews_New.aspx`, 30 items per page, stops when a page's
  oldest item is before the window start)
- Result: 97 pages, all HTTP 200, 2026-09-27 14:39 -> 14:43. Pages per ticker from 5 (ACB)
  to 15 (MBB, TCB). Saved to `raw/news/ticker/`.
- Run: `sql/01_ddl/020_raw_ticker_news.sql`, then `python ingest/load_ticker_news.py`
- Checked with: `sql/04_quality/020_raw_ticker_news_checks.sql`
- Result: `raw.raw_ticker_news` 2,910 rows. All times parse as dd/mm/yyyy, no link listed twice
  for the same ticker, no missing values. 496 articles + 2,414 disclosures = 2,910.
  Inside the window: 2,733 items, 2,274 disclosures, 459 articles.
- Time 00:00: on articles it is a real midnight publish time (checked 2 pages), on disclosures
  it means date only (about 92% of disclosures).
- Issue: the first kind check used `LIKE '%-188%.chn%'` and counted one SHB disclosure as an
  article (its slug has "1882025" = 18.8.2025). Found because articles + disclosures for SHB came
  to 301 against 300 items. Kind now comes from the URL path (`/du-lieu/` = disclosure).

### 1.7 Sitemaps
- Run: `python ingest/crawl_sitemaps.py` (buckets picked from the sitemap index, one extra on each side)
- Result: 146 bucket files, 2024-09-21 -> 2026-09-30, 185 MB, 147 requests all HTTP 200,
  2026-09-28 04:09 -> 04:14. Every file ends with `</urlset>`.
- 248,649 entries, 248,415 distinct URLs. 230 URLs appear in two files and 2 in three, each time
  with a different lastmod. Every day in the window has entries.

### 1.8 lastmod vs publish time, 50-article sample
- Run: `python ingest/sample_lastmod.py` (fixed seed 20260928, strata by lastmod minus the
  timestamp in the URL ID), then `sql/01_ddl/030_raw_lastmod_sample.sql`,
  `python ingest/load_lastmod_sample.py`
- Checked with: `sql/04_quality/030_lastmod_sample_analysis.sql`
  (session rule: before 15:00 -> first trading day on or after the date, from 15:00 -> first
  trading day after it; calendar from `raw.raw_calendar`)
- Result:

  | Stratum | Lag | Population | Sampled | Different session |
  |---|---|---|---|---|
  | A | < 1 h | 201,627 | 14 | 1 |
  | B | 1-6 h | 25,378 | 14 | 0 |
  | C | 6-24 h | 13,732 | 11 | 2 |
  | D | >= 24 h | 5,320 | 11 | 8 |

  Weighted by population: 8.4% of 246,057 articles get a different session from lastmod.
  Wide margin, since stratum A (82% of articles) rests on 1 of 14.
- Decision: publish time comes from the article page (`decisions.md`).

### 1.9 Article pages
- Candidates: sitemap titles matching `config/news_prefilter.yaml` (tickers, bank names,
  "ngân hàng") -> 10,966 URLs.
- Run: `python ingest/fetch_article_pages.py --limit 20` first, then without `--limit`,
  in several runs.
- Result: 2026-09-28 15:05 -> 2026-09-29 07:13. 10,959 pages saved as gzip (281 MB, about 22%
  of the raw size), 7 returned 404, 2 returned 504 and succeeded on retry. Nothing left to fetch.
- The filter is wide on purpose and catches non-bank titles ("thủy ngân hàng top",
  "Đại học Ngoại thương", "tiên phong" as a common word).

### 1.10 Raw article tables
- Run: `sql/01_ddl/040_raw_article.sql`, then `python ingest/load_articles.py`
- Checked with: `sql/04_quality/040_raw_article_checks.sql`
- Result: `raw.raw_article` 248,649 rows from 146 files. `raw.raw_article_page` 10,959 rows.
  No lastmod that fails to convert, no empty title, every page ties to a sitemap URL.
- 94 pages (0.9%) have no `article:published_time`: long-form sponsored pages with no date at all.
- 593 pages (5.4%) have a sitemap title that differs from `og:title` in wording.
- 39 sitemap titles are not in Unicode NFC.
- Issue: 1,134 titles still had `&amp;` (CafeF puts HTML entities inside the CDATA). The loader
  now decodes the inner text once more; the check went to 0.
- Issue: the first run of the loader (while the page fetcher was still running) did not work; the
  error message wasn't kept. Two likely causes were fixed: all 248,649 rows went into one
  `executemany` call (fast_executemany sizes a buffer for every row), and a half-written last
  line of the fetch log could be read. Inserts now go in batches of 5,000 inside the same
  transaction and incomplete log lines are skipped. The next runs worked, also during the fetch.

### Rebuild Phase 1 from the saved files (no network)
Run in this order. The downloads themselves can't be repeated exactly: VCI adjusts history and
CafeF pages change.

```
-- SSMS
sql/01_ddl/010_raw_price_tables.sql
sql/01_ddl/020_raw_ticker_news.sql
sql/01_ddl/030_raw_lastmod_sample.sql
sql/01_ddl/040_raw_article.sql
```
```
python ingest/load_prices.py
python ingest/load_ticker_news.py
python ingest/load_lastmod_sample.py
python ingest/load_articles.py
```
Then the checks `sql/04_quality/010` to `040`.

### Carried into later phases
- Phase 2: tick-grid test; check VCI cash-dividend adjustment around the VCB/CTG ex-date
  2026-07-23 (450 đ/cp); make sure every price time is 00:00:00 before casting to date;
  one row per article URL; keep or cut the ~100 sessions before `base_date`.
- Phase 3: check the other 9 tickers for name changes in the window.
- Phase 5/7: count matched articles with time_source = 'lastmod' and report them apart; lastmod
  can be days before the real publish time (2.5).
- Phase 5: match on word boundaries, re-test the 39 non-NFC titles (no NFC step, see decisions), decide sitemap title vs og:title,
  exclusion list for subsidiaries (e.g. "VietinBank Capital"), flag pages without a publish time
  (mostly sponsored), map date-only disclosures to a session, recall against the per-ticker list.

---

## Phase 2 - Staging (2026-09-29 to 2026-09-30)

Decisions for this phase are in `decisions.md` (2026-09-29): cut prices to the locked window,
config snapshot in the database, staging as real tables with primary keys.

### 2.1 Can the raw price values be typed?
- Checked with: `sql/04_quality/010_raw_price_checks.sql`, query 6 (TRY_CONVERT counts).
- Result: 6,000 + 600 rows. Every time converts and is 00:00:00, every price converts to
  DECIMAL(18,4), no scientific notation, every volume converts to BIGINT. At most 2 decimals.

### 2.2 Config snapshot and price staging
- Run: `sql/01_ddl/050_raw_config.sql`, `sql/01_ddl/100_stg_price.sql`,
  `python ingest/load_config.py`, `sql/02_load/100_load_stg_price.sql`
- Checked with: `sql/04_quality/100_stg_price_checks.sql`
- The load stops (THROW) if any raw time isn't midnight, and uses CAST so a value that doesn't
  convert stops the load instead of becoming NULL.
- `python ingest/load_config.py` -> raw_scope 1 row, raw_ticker_config 10, raw_ticker_name_history 2 (STB).
- Result: stg_calendar 497 sessions, stg_price_daily 4,970 rows = 10 x 497. Every ticker runs
  2024-09-26 -> 2026-09-25. No ticker-date missing from the calendar or the other way round.
  raw -> stg per ticker: 497 in the window, 103 cut before it, 0 after; nothing lost.
  No non-positive price, no low/high that fails to bracket open/close, no zero-volume session.

### 2.3 Price adjustment (tick grid) and the ±7% band
- Checked with: `sql/04_quality/110_stg_price_adjustment_checks.sql`, details in `price_adjustment_check.md`.
- 9 tickers adjusted by VCI (off grid up to their latest corporate action). STB 0% off grid:
  no dividend, bonus or rights event in the window.
- VCB and CTG: off grid before the 2026-07-23 cash-dividend ex-date, 0 off grid from it.
  VCI adjusts for cash dividends.
- 5 sessions beyond 7%, all up to 7.5% (ceiling/floor). None beyond 7.5%.
- Ex-date cross-check (query 7): for all 9 tickers with an event, the last off-grid close is on or
  before the session before the latest ex-date, 0 off grid from it. Cash, share, bonus and rights
  events are all adjusted.
- Repeated closes (`100_stg_price_checks.sql` queries 7 and 8): 27 to 79 per ticker, 50 runs of
  3+ sessions. No repeated full bar; every run has a different volume each session. Real sessions, kept.

### 2.4 Checks before news staging
- Checked with: `sql/04_quality/040_raw_article_checks.sql` queries 6 to 10,
  `sql/04_quality/020_raw_ticker_news_checks.sql` queries 7 and 8.
- Repeated URLs: 232, 25 of them with different titles in different bucket files; lastmod gap
  between rows of one URL 0.4 h to 696 h.
- Titles with combining marks: raw_article 39, og_title 3, ticker list 0. Vietnamese_100_CI_AS
  treats "Thường" and its decomposed form as equal (= and LIKE); BIN2 doesn't.
- published_time: all 10,865 values are 19 characters, yyyy-mm-ddThh:mm:ss.
- URL: longest 254, all ASCII, all https://cafef.vn/... with no query string.
- Per-ticker list vs sitemap, items inside the window: 459 articles, 387 found by URL, 312 with a
  fetched page; 2,274 disclosures, none in the sitemap (disclosures live under /du-lieu/).
- The 72 article rows not found by URL are 49 articles; 48 are in the sitemap under the same id with
  another slug, 1 is not in the sitemap at all (TCB, 2025-09-17, id 188250916101159515).
- The 75 found articles without a fetched page have titles that don't pass the prefilter
  (no ticker, bank name or "ngân hàng"): a first look at title-only recall for Phase 5.
- article_id: 248,415 URLs, 248,350 ids, all digits, 15 to 18 long. 64 ids are shared by 2 or 3
  different articles (129 URLs). None of the per-ticker list ids is among them.

### 2.5 News staging
- Run: `sql/01_ddl/110_stg_news.sql`, `sql/02_load/110_load_stg_news.sql`
- Checked with: `sql/04_quality/120_stg_news_checks.sql`
- stg_article 246,056 rows. raw 248,415 distinct URLs = 1,421 before the window + 246,056 in it
  + 938 after it (the extra sitemap buckets at both ends).
- Time source: page 10,741; lastmod with a fetched page but no page time 92; lastmod without a
  fetched page 235,223.
- Repeated URLs: 230 with 2 rows (23 with another title in raw), 2 with 3 rows (both).
- Shared article_id inside the window: 64 ids, 127 URLs; 245,993 distinct ids.
- Page time vs lastmod on the 10,741 pages: different date 1,136; lastmod earlier than the page
  time 3,462; range -480 h to +1,029 h.
- Breakdown (query 5b), lastmod minus page time:

  | Bucket | Pages | Different date |
  |---|---|---|
  | lastmod > 1 h earlier | 1,352 | 482 |
  | lastmod 1 min to 1 h earlier | 2,006 | 83 |
  | lastmod < 1 min earlier | 104 | 1 |
  | 0 to 1 h later | 5,774 | 0 |
  | 1 h to 24 h later | 1,204 | 269 |
  | 24 h or more later | 301 | 301 |

- Rounding to the minute explains only 104 pages. lastmod is off in both directions:
  - Earlier (query 5c): page times on round hours (08:00, 07:45, 13:30), lastmod up to 20 days
    before, several PR-style titles. Looks like articles saved first and published at a set time.
  - Later (query 5c): the 10 largest are pages from February 2026 whose lastmod is 2026-03-16
    16:44-16:47 or 2026-03-17 09:14. Looks like a batch re-save that moved lastmod.
  - Both are readings of the top rows, not checked against CafeF.
- Consequence: for an article that falls back to lastmod, the time can be later than the real
  publish time or earlier. Earlier is the risky side: the article would look like it came before a
  price move it actually followed.
- Titles with combining marks: sitemap 39, og_title 3 (all inside the window).
- stg_ticker_news 2,733 rows = raw items inside the window. 459 articles, 2,274 disclosures,
  2,087 disclosures date-only. Articles per ticker from 25 (TPB) to 107 (TCB).
- Per-ticker articles against stg_article: 387 rows (301 articles) by URL, 71 rows (48 articles)
  by article_id, 1 not matched (TCB 2025-09-17, not in the sitemap). 350 distinct articles.

---

## Phase 3 - Dimensional model (2026-09-30 to 2026-10-01)

### 3.1 Name changes in the window
- Checked with: `sql/04_quality/200_rename_check.sql`, web search, bank documents
  (sources in `decisions.md`).
- Query 1 (article titles about a rename + a bank name): 12 articles. 8 about STB
  (2026-02-24 to 2026-06-04), the rest about CB -> VCBNeo, VietinBank Securities and
  SHB Finance -> SFinance.
- Query 2 (disclosures about a name or the licence, branch and office renames left out): licence
  amendments and re-issues only; TCB (2026-03-18) and SHB (2026-04-17) re-issues keep the same name.
- Result: STB is the only rename. dim_ticker: 10 tickers, 11 rows.
- Side finding: STB's per-ticker list has a disclosure titled "... Giấy phép ... của MB"
  (2025-03-18). The per-ticker list can carry an item of another bank, so it is a recall reference,
  not ground truth, in Phase 5.

### 3.2 dim_date
- Run: `sql/01_ddl/300_dw_dim_date.sql`, `sql/03_transform/300_load_dim_date.sql`
- Checked with: `sql/04_quality/300_dim_date_checks.sql`
- 730 days = days in the window, 2024-09-26 to 2026-09-25, no duplicate date.
- 497 trading days = sessions in stg_calendar; session_seq 1 to 497, no gap, no break.
- No calendar session missing, no trading day outside the calendar, no trading day on a weekend.
- 730 - 208 weekend days - 497 sessions = 25 weekdays without a session (holidays; list in query 6).
- day_of_week 1 = Monday. Thursday and Friday have 105 days, the others 104: the window starts on a
  Thursday and ends on a Friday (104 weeks + 2 days).
- session_seq_on_or_after was proposed and dropped; Phase 5 finds the reaction session itself.

### 3.3 dim_ticker
- Run: `sql/01_ddl/310_dw_dim_ticker.sql`, `sql/03_transform/310_load_dim_ticker.sql`
- Checked with: `sql/04_quality/310_dim_ticker_checks.sql`
- 11 rows for 10 tickers; one current version per ticker; STB has 2 versions (keys 6 and 7).
- No gap or overlap between versions, every ticker covered from 1900-01-01 to 9999-12-31, every
  (ticker, session) in staging matches exactly one version.
- STB sessions: 415 under the old name (2024-09-26 to 2026-05-29), 82 under the new name
  (2026-06-01 to 2026-09-25); 415 + 82 = 497.

### 3.4 dim_article
- Run: `sql/01_ddl/320_dw_dim_article.sql`, `sql/03_transform/320_load_dim_article.sql`
- Checked with: `sql/04_quality/320_dim_article_checks.sql`
- 248,330 rows: 246,056 articles (page time 10,741, lastmod 235,315) = stg_article, and 2,274
  disclosures = distinct disclosure URLs in stg_ticker_news. No disclosure URL is listed under two
  tickers. Every staging URL is in the dimension and every dimension row has a staging source.
- Disclosures: 2,087 date-only, 187 with a time. The ones with a time all fall on or after
  2025-04-14; before that date every disclosure is date-only. Input for mapping disclosures to a
  session in Phase 5.
- Every item's publish date is in dim_date.

### 3.5 fact_price_daily
- Grain: one row per ticker per trading session (periodic snapshot).
- Run: `sql/01_ddl/330_dw_fact_price_daily.sql`, `sql/03_transform/330_load_fact_price_daily.sql`
- Checked with: `sql/04_quality/330_fact_price_daily_checks.sql`
- 4,970 rows = stg_price_daily. No duplicate (ticker, session) when grouped by the durable ticker;
  every ticker has as many rows as trading days in dim_date; no row on a non-trading day; every
  row carries the ticker version valid on its date; values equal staging in both directions (EXCEPT).
- STB: 415 rows on key 6 (to 2026-05-29), 82 on key 7 (from 2026-06-01).
- From here, TRUNCATE on dim_date / dim_ticker fails (referenced by foreign keys); dimension reloads
  move to the Phase 4 procedures.

### 3.6 fact_news (structure only)
- Grain: one row per news item per bank (of the 10) the item is tied to. Factless.
- Run: `sql/01_ddl/340_dw_fact_news.sql`. Rows come in Phase 5.
- dim_date in two roles: publish_date_key, reaction_date_key (nullable: the reaction session can
  fall after the window, and dim_date stays continuous, so no placeholder date row).
- ticker_key = version valid on the publish date. match_tier (0 = disclosure from the bank's own
  list, 1-3 = title rules) and banks_mentioned on the fact row; is_sector_news is a persisted
  computed column (banks_mentioned >= 3), so the flag can't disagree with the count.
- Checks ready in `sql/04_quality/340_fact_news_checks.sql` (grain by durable ticker, the two date
  roles, ticker version on the publish date).
- Structure checked: 4 foreign keys (article, ticker, publish date, reaction date);
  is_sector_news is persisted.

---

## Phase 4 - Load procedures and incremental load (2026-10-01)

Decisions in `decisions.md` (2026-10-01): revised prices restate the whole ticker and are logged;
procedure tests run inside a transaction that is rolled back.

### 4.1 Procedures
- `sql/01_ddl/400_dw_price_revision_log.sql`
- `sql/03_transform/400_sp_load_dim_date.sql` (MERGE on date_key)
- `sql/03_transform/410_sp_load_dim_ticker.sql` (MERGE on ticker + valid_from, SCD2; written by Binh)
- `sql/03_transform/420_sp_load_dim_article.sql` (MERGE on url, Type 1)
- `sql/03_transform/430_sp_load_fact_price_daily.sql` (re-key, revisions, restatement, insert; @to_date)
- All four open a transaction only when called outside one, and never commit or roll back a
  caller's transaction.
- First run on the Phase 3 data: every count 0.

### 4.2 Tests
- Run: `sql/04_quality/400_phase4_tests.sql` (one window; each test rolled back).
- Test 1, all four procedures twice: every count 0 in both runs.
- Test 2, incremental: fact emptied, run with @to_date = 2025-09-30 -> 2,520 rows (10 x 252
  sessions), last date 2025-09-30; second run -> +2,450 = 4,970. EXCEPT with staging: 0 both ways.
- Test 3, revised prices: VCB staged prices before 2026-03-02 x 0.98 (353 sessions). Load: 353
  revised sessions logged (2024-09-26 to 2026-02-27, e.g. close 60.92 -> 59.70), 1 ticker restated,
  497 rows deleted and 497 inserted; every ticker's fact close equals staging.
- Test 4, new rename: VCB renamed from 2026-07-01 in the raw config. dim_ticker: 1 insert (key 12),
  1 update (key 10 closed at 2026-06-30). Fact: 60 rows re-keyed; VCB = 437 rows on key 10 + 60 on
  key 12 = 497. No duplicate (ticker, session). The filtered unique index on current versions
  raised no error.
- Test 5, state after all tests: row counts and checksums of dim_ticker, fact_price_daily,
  price_revision_log, raw_ticker_config, raw_ticker_name_history, stg_price_daily equal the
  snapshot taken before.
- Identity values used inside the rolled-back tests are not returned: the next real dim_ticker
  version will get key 13, not 12.

### 4.3 One call for the whole warehouse load
- `sql/03_transform/490_sp_load_dw.sql`: dw.sp_load_dw runs dim_date, dim_ticker, dim_article,
  fact_price_daily in that order inside one transaction.
- `EXEC dw.sp_load_dw;` on the loaded warehouse: every count 0.

---

## Phase 5 - Matching news to banks (from 2026-10-02)

Decisions in `decisions.md` (2026-10-02): alias table in three tiers; date-only disclosures react on
the next session; "MB" moves to tier 2 with two guards; same-session cutoff 14:45.

### 5.1 Alias table
- Survey: `sql/04_quality/500_alias_discovery.sql`, notes in `docs/alias_survey.md`.
- `config/aliases.yaml` -> `ingest/load_aliases.py` -> `raw.raw_alias` (107 rows)
  -> `sql/02_load/120_load_stg_alias.sql` -> stg_bank 42 (10 in scope, 32 outside),
  stg_alias 86, stg_alias_context 2, stg_alias_exclusion 29.
- Terms by tier: in scope tier 1 10 terms, tier 2 30 terms; outside banks tier 2 46 terms;
  no tier 3 entry.

### 5.2 Title matching
- `sql/03_transform/500_match_articles.sql` -> `stg.stg_article_bank_match`.
- In-scope tier 1: 792 article-bank pairs (747 articles); tier 2: 3,813 pairs (2,721 articles).
  Outside banks: 2,951 pairs (2,586 articles).
- Articles per bank: ACB 419, CTG 640, HDB 313, MBB 514, SHB 240, STB 472, TCB 489, TPB 171,
  VCB 830, VPB 517. MBB by term: MB 457, MBBank 35, MBB 16.
- Titles with "MB" (upper case, whole word) not matched to MBB: 20, all read. 18 exclusions,
  1 file size ("8 MB"), 1 bank title ("Ngân hàng BIG5 MB") dropped by the number rule. Rule changed
  to need a digit not glued to a letter; rerun: tier 2 +1 pair (article 108797 -> MBB, term MB),
  everything else unchanged.
- Banks named per article (all banks): 1 bank 4,589 articles (2,614 with an in-scope bank),
  2: 208, 3: 193, 4: 171, 5: 59, 6: 24, 7: 95, 8: 6.
- Checks: `sql/04_quality/510_match_checks.sql`.

### 5.3 fact_news
- `sql/03_transform/510_sp_load_fact_news.sql` (full rebuild from the match table and the
  disclosure lists; reaction session with the 14:45 cutoff).
- `EXEC dw.sp_load_fact_news;` twice: second run deleted 6,879, inserted 6,879, outside_window 0.
- By source: 4,605 article pairs (tier 1-2) = in-scope rows in stg_article_bank_match;
  2,274 disclosure pairs (tier 0) = disclosure rows in stg_ticker_news.
- Checks: `sql/04_quality/340_fact_news_checks.sql` queries 1-12. Queries 1-4 and 7-9 return no
  rows; query 6 (pairs, EXCEPT both ways) 0 and 0.
- Rows by tier and sector flag (query 5):

  | match_tier | is_sector_news | rows | items | no reaction session |
  |---|---|---|---|---|
  | 0 | 0 | 2,274 | 2,274 | 4 |
  | 1 | 0 | 665 | 649 | 0 |
  | 1 | 1 | 127 | 98 | 0 |
  | 2 | 0 | 2,236 | 2,177 | 6 |
  | 2 | 1 | 1,577 | 544 | 7 |

  Every disclosure is on one bank's list only (2,274 rows, 2,274 items); none is sector news.
- Reaction session, distinct items (query 10):

  | item_type | has_time | same day | later session | after window |
  |---|---|---|---|---|
  | article | 1 | 1,487 | 1,874 | 6 |
  | disclosure | 0 | 0 | 2,087 | 0 |
  | disclosure | 1 | 41 | 142 | 4 |

- Items published 14:45-15:00 on a trading day, moved to the next session by the 14:45 cutoff
  (query 11): 60.
- Per bank (query 12): rows / not sector / sector / disclosures

  | ticker | rows | not sector | sector | disclosures |
  |---|---|---|---|---|
  | ACB | 527 | 460 | 67 | 108 |
  | CTG | 830 | 459 | 371 | 190 |
  | HDB | 618 | 474 | 144 | 305 |
  | MBB | 932 | 708 | 224 | 418 |
  | SHB | 474 | 445 | 29 | 234 |
  | STB | 639 | 487 | 152 | 167 |
  | TCB | 818 | 703 | 115 | 329 |
  | TPB | 328 | 301 | 27 | 157 |
  | VCB | 969 | 539 | 430 | 139 |
  | VPB | 744 | 599 | 145 | 227 |

### 5.4 Precision sample
- `sql/01_ddl/070_raw_precision_label.sql`, `sql/04_quality/520_precision_sample.sql`
  (view stg.v_precision_sample), `ingest/export_precision_sample.py`,
  `ingest/load_precision_labels.py`.
- Sample (query 1): t0_disclosure 50 of 2,274; t1_ticker 75 of 792; t2_mb 75 of 410; t2_other 100
  of 3,403. t2_mb + t2_other = 3,813 = tier 2 pairs; 47 pairs with "MB" as matched term also match
  another MBB term and sit in t2_other.
- Fingerprint (query 2): 300 pairs, CHECKSUM_AGG -220953767.
- One run of the whole 520 file took 4 min 20 s. Re-run step by step (`521_precision_sample_timing.sql`,
  results into #temp, session waits before/after): each statement 3-346 ms; the CREATE OR ALTER VIEW
  batch alone under 1 s; no open transaction. The slow run was not seen again and its cause was not
  observed. If it comes back: Part B of 521 in a second tab while it runs.
- Export: `docs/precision_sample.csv`, 300 rows (50 / 75 / 75 / 100), UTF-8 with BOM, committed as
  exported. A first Excel save as "CSV (Comma delimited)" wrote Windows-1252 and turned 2,307
  characters into "?"; file deleted and exported again. Saved as "CSV UTF-8": only
  publish_time_local changed (date format), url / ticker / title unchanged.
- Round trip: `load_precision_labels.py` -> raw.raw_precision_label 300 rows (separator ','); 520
  query 3: 0 rows both ways.
- Labelling (2026-10-05 to 2026-10-06): 300 rows in seven batches; each batch reviewed against the case
  table, the rows that broke a rule fixed. Rows off the rules per batch: 13 of 20, 7 of 35 (rows
  21-55), 11 of 46, 9 of 50, 10 of 51, 10 of 51, 1 of 47.
- Final file: 300 rows labelled, all with a case note (B 118, D 80, A 30, C2 18, E 18, H 14, C1 14,
  C3 6, F 2); note/label cross-check: 0 conflicts. Labels committed in d28ca8a; notes for the 34 rows
  of the first batches added after.
- Staging: `sql/01_ddl/140_stg_precision_label.sql`, `sql/02_load/130_load_stg_precision_label.sql`
  (THROW 50100-50105 on missing labels, is_correct 0 with main subject 1, duplicate pairs, mixed
  stratum sizes, unknown case codes, codes that contradict the labels).

### 5.5 Precision results
Run: `sql/04_quality/530_precision_report.sql` on stg.stg_precision_label (300 pairs). These figures
are for the matching rules as they stood when the sample was drawn (before any fix below).

Per stratum (95% Wilson interval):

| stratum | n | stratum size | match | match 95% | usable | usable 95% |
|---|---|---|---|---|---|---|
| t0_disclosure | 50 | 2,274 | 50/50 = 1.000 | 0.929 - 1.000 | 50/50 = 1.000 | 0.929 - 1.000 |
| t1_ticker | 75 | 792 | 75/75 = 1.000 | 0.951 - 1.000 | 49/75 = 0.653 | 0.541 - 0.751 |
| t2_mb | 75 | 410 | 75/75 = 1.000 | 0.951 - 1.000 | 29/75 = 0.387 | 0.285 - 0.500 |
| t2_other | 100 | 3,403 | 98/100 = 0.980 | 0.930 - 0.995 | 46/100 = 0.460 | 0.366 - 0.557 |

Weighted by stratum size:

| scope | labelled | pairs | match | usable |
|---|---|---|---|---|
| all | 300 | 6,879 | 0.990 | 0.656 |
| articles (t1, t2) | 250 | 4,605 | 0.985 | 0.487 |

- The two wrong matches are the same case: "Sacombank" in silver price titles (Sacombank-SBJ, rows 19
  and 132).
- A stratum with 100% match is reported with its lower bound (at least 0.93-0.95 at 95%), not as
  "100% correct".
- Disclosures (t0) do not go through the title rules; the matching figure for the title rules is the
  articles row.

Sector flag (is_sector_news) against the human label, correct matches only (298 pairs, sample
counts, not weighted):

| | not main subject | main subject |
|---|---|---|
| flag 0 (kept) | 41 | 160 |
| flag 1 (dropped) | 83 | 14 |

- The strata are sampled at different rates (all 50 disclosures sit in flag 0 / main subject), so
  these counts describe the sample, not the population.
- 530 query 3b: every labelled pair still has a fact_news row.

### 5.6 Conditional exclusion for "Sacombank" in silver price titles (2026-10-07)
Decision in `decisions.md` (2026-10-07). Measured before the fix (510 query 10b shape): 32 STB titles
with a gold/silver word, 30 of them silver price lists containing "giá bạc".
- Changed: `config/aliases.yaml` (exclusion with when_title_contains), `ingest/load_aliases.py`,
  `060_raw_alias.sql` and `120_stg_alias.sql` (column when_title_contains, ALTER for existing tables),
  `120_load_stg_alias.sql` (50073 limited to unconditional exclusions, new 50074), `500_match_articles.sql`.
- Counts predicted before the run and found after it:

  | step | before | after |
  |---|---|---|
  | raw.raw_alias rows | 107 | 108 |
  | stg_alias_exclusion | 29 | 30 |
  | in-scope tier 2 pairs / articles | 3,813 / 2,721 | 3,783 / 2,691 |
  | in-scope tier 1, outside banks | unchanged | unchanged |
  | fact_news rows | 6,879 | 6,849 |
  | STB rows in fact_news (not sector) | 639 (487) | 609 (457) |
  | labelled pairs not in current sample (130) | 0 | 2 (t2_other, rows 19 and 132) |

- 340 checks: queries 1-4 and 7-9 no rows; query 6 0 and 0. 510 query 10a: every title with
  "Sacombank" and "giá bạc" has stb_matched = 0; 10b: 2 titles kept (36548, 182130).
- 530 figures unchanged (labels unchanged); they remain the precision of the rules before this fix.

