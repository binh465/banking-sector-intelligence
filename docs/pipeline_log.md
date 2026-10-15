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

### 5.7 Agreement with CafeF's per-ticker article lists
Run: `sql/04_quality/540_ticker_list_agreement.sql` (after the 5.6 fix). Not a true recall: CafeF tags
by the article body, the rules read the title only, and a list can carry an item about another bank.

| ticker | list | not in sitemap | matched | other banks only | no bank |
|---|---|---|---|---|---|
| ACB | 36 | 4 | 21 | 4 | 7 |
| CTG | 29 | 6 | 10 | 2 | 11 |
| HDB | 58 | 7 | 30 | 3 | 18 |
| MBB | 29 | 4 | 11 | 3 | 11 |
| SHB | 48 | 9 | 23 | 0 | 16 |
| STB | 43 | 7 | 25 | 2 | 9 |
| TCB | 107 | 17 | 58 | 3 | 29 |
| TPB | 25 | 5 | 12 | 1 | 7 |
| VCB | 40 | 4 | 17 | 1 | 18 |
| VPB | 44 | 9 | 20 | 1 | 14 |
| all | 459 | 72 | 227 | 20 | 140 |

- No list article outside the window. 72 (16%) are not in the crawled sitemaps: a source gap, kept
  out of the rate.
- Agreement on the 387 articles the rules can read: 227 / 387 = 0.587.
- The 160 list pairs not matched to their own ticker (83 distinct articles; one round-up sits on up
  to 9 lists) were read one by one (titles read by Claude, listed for Binh):
  - title names the bank under a term missing from the alias table: 0. No alias added.
  - excluded on purpose: 1 (SHBFinance, a subsidiary).
  - single unnamed bank as the subject ("Một ngân hàng ...", "Ngân hàng đắt giá nhất Việt Nam ...",
    "Một cổ phiếu ngân hàng ..."): 18 pairs, 18 articles. These are bank-specific news the title rules
    cannot see.
  - the rest (141 pairs, of which 20 name other banks only): round-ups of many companies or banks,
    stories about people (owners, chairmen by nickname), generic titles. Most would be sector items.
- So the title rules miss no named bank; the loss is titles that do not name the bank. Reaching those
  needs the article body, which is out of scope.

### 5.8 Titles not in NFC
Run: `sql/04_quality/550_non_nfc_titles.sql`.
- Query 1: no case-sensitive alias or exclusion with a non-ASCII character.
- Query 2: decomposed "Ngân hàng Quân đội" (LEN 21, NFC 18) matches the 500 pattern under the
  database collation (1), not under BIN2 (0).
- Query 3: 39 non-NFC article titles. 3 name a bank, all matched (Vietbank, Agribank, BVBank, all
  outside the 10); 36 name no bank (real estate, jewellery, airline and similar). No miss.

### 5.9 Sitemap title vs og:title
Run: `sql/04_quality/560_title_vs_og_title.sql`. Decision in `decisions.md` (2026-10-07).
- Articles 246,056; with og:title 10,833; og:title differs from the sitemap title 576.
- Alias terms on the 576 (screen, no exclusions or guards):

  | banks | in both | sitemap title only | og:title only |
  |---|---|---|---|
  | in scope | 122 | 20 | 14 |
  | outside the 10 | 29 | 5 | 7 |

- The 14 in-scope og-only pairs were read: mostly headlines that name the bank in og:title and hide
  it in the sitemap title ("một ngân hàng", "một cổ phiếu ngân hàng").
- Kept: matching reads the sitemap title for every article.

---

## Phase 6 - Analysis views (from 2026-10-08)

Views in schema `mart`, files `sql/03_transform/600-...`. Every window function partitions by
`ticker` (durable key) and orders by `session_seq`.

### 6.1-6.3 Return and sector index views
- `v_price_session`, `v_return_daily`, `v_sector_return`, `v_sector_index` (600-630).
- Return checks pass, including agreement with the five moves beyond 7% listed in Phase 2.
- 497 sessions; `sector_ret` is NULL only at session 1; every later session has all 10 returns.
- `sector_index` = 100 at session 1; index(s) / index(s-1) - 1 reproduces `sector_ret` to 3.3E-16.
- Session 2: `AVG(ret)` from `v_return_daily` equals `sector_ret`.
- Last session: average of ticker base-100 indexes 140.73, sector index 141.34.
  The sector index is a daily-rebalanced equal-weight series; the average of indexes is
  equal-weight buy-and-hold. The gap is the effect of rebalancing over this window.

### 6.4 Ticker index
- `v_ticker_index` (640): base 100 per ticker, compounded from `ret` the same way as the sector index.
- 497 rows per ticker, 100 at session 1 for every ticker.
- Against 100 * close / first close on every row: largest relative difference 3.3E-15, so no ticker
  has a missing session.
- Average of the 10 ticker indexes at the last session: 140.729265897882, same as 6.1-6.3.

### 6.5 Relative strength and excess return
- `v_relative_strength` (650): `excess_ret` = ret - sector_ret (input to the z-score);
  `rs` = 100 * ticker_index / sector_index (charts only, it trends).
- 497 rows per ticker; one NULL `excess_ret` per ticker (session 1); `rs` = 100 at session 1.
- Sum of the 10 excess returns per session: largest absolute value 5.6E-17.
- Last session, `rs` from highest to lowest: STB 165.27, VPB 109.43, HDB 108.19, MBB 104.76,
  TCB 102.33, SHB 100.82, CTG 86.75, ACB 80.88, TPB 69.89, VCB 67.36. Mean 99.57, below 100 by the
  same ratio as 140.73 / 141.34 (sector index is rebalanced daily, not an average of indexes).
- This ranks the whole window only. When a ticker started to diverge is the z-score step (6.7).

### 6.6 Rolling correlation, 60 sessions
- `v_rolling_corr` (660): correlation of ticker return with sector return over the current session
  and the 59 before it, from six running sums; returned only when the window holds 60 pairs.
- 60 NULL `corr_60` per ticker, first value at session 61; all values inside [-1, 1].
- Range per ticker (min / max): ACB 0.59 / 0.96, CTG 0.55 / 0.95, HDB 0.45 / 0.92,
  MBB 0.64 / 0.94, SHB 0.31 / 0.88, STB 0.31 / 0.90, TCB 0.57 / 0.91, TPB 0.55 / 0.91,
  VCB 0.34 / 0.93, VPB 0.64 / 0.92.
- Recomputed by definition (mean-centred products over STDEVP) for ACB at session 200:
  0.631131391695342 in both.
- The sector includes the ticker itself (1/10 weight), which pushes the correlation up. For
  Limitations.

### 6.7 Z-score on excess return
- `v_excess_zscore` (670): window ROWS BETWEEN 60 PRECEDING AND 1 PRECEDING, partitioned by ticker;
  z only when the window holds 60 excess returns and the current one exists. Sample sd (STDEV).
- 61 NULL z per ticker, first z at session 62 (the window of session 61 still holds session 1, which
  has no return).
- Recomputed by definition for STB at session 62 (-0.185107235278076) and session 300
  (-0.217354933808168): equal in both.
- Per ticker 436 sessions with z; |z| >= 2: 26-36, |z| >= 3: 7-13 (MBB 13, VCB 13, SHB 12, ACB 11,
  VPB 10, TCB 9, CTG 9, HDB 8, TPB 8, STB 7); max |z| 4.31 (ACB) to 8.15 (TPB).
- Threshold |z| >= 3 chosen, see `decisions.md` (2026-10-09).

### 6.7 Rolling IQR, first version: OUTER APPLY
- `v_excess_iqr` (680), first version: for each session, OUTER APPLY with TOP (1) takes the 60 earlier
  excess returns of the same ticker from `v_relative_strength` and computes Q1, median, Q3 with
  PERCENTILE_CONT ... OVER (). PERCENTILE_CONT does not accept a ROWS frame, hence the subquery.
- `SELECT COUNT(*)` on the view: 19 ms, but the plan has no APPLY branch and no window operators.
  The OUTER APPLY with TOP (1) cannot change the row count, so the optimizer drops it, and the window
  functions with it, when no column from them is used. Not a measure of the view.
- Measured with `SELECT SUM(out_1_5), SUM(out_3), SUM(q1), SUM(q3)` (STATISTICS TIME, IO):
  CPU 116,828 ms, elapsed 123,402 ms.

  | table | scan count | logical reads |
  |---|---|---|
  | fact_price_daily | 14,893 | 595,720 |
  | dim_date | 14,893 | 119,144 |
  | dim_ticker | 9,932 | 129,006 |
  | Worktable | 29,828 | 2,433,000 |

- Scan counts are small multiples of the 4,970 outer rows: the inner side recomputes the whole view
  chain once per outer row (fact_price_daily read three times each: ticker branch, sector branch, and
  the ticker count in 620). The ticker predicate does not help the sector branch, which needs all 10
  tickers, and the session range cannot be pushed below the window functions.

### 6.7 Rolling IQR, set-based version
- `v_excess_iqr` (680) rewritten: each session joined to its 60 earlier sessions (same ticker,
  session_seq s-60 .. s-1), percentiles per (ticker, session_seq) over those rows, DISTINCT to one row,
  LEFT JOIN back so sessions without earlier rows are kept.
- Same result as the OUTER APPLY version (commit fb90105): 4,970 rows compared one by one (FULL JOIN,
  EXISTS ... EXCEPT, NULL = NULL), none on one side only, none differ.
- Measured with the same SUM query: CPU 4,375 ms, elapsed 5,776 ms (was 123,402 ms).
  fact_price_daily scan count 8 (was 14,893); Worktable 4,985 scans, 2,905,004 logical reads.
- Actual plan:
  - the self-join runs as Nested Loops over an eager Index Spool built once on the inner side and
    sought 4,970 times (about 0.3 s);
  - a hash join inside the inlined view chain produces 2,799,000 rows (estimate 22,692) before being
    filtered back to 279,900: the sector branch is joined by session before the ticker filter;
  - Sort of 279,300 rows and a hash both spill to tempdb (962 and 2,040 pages); grant 11.6 MB,
    3.6 MB used, split by estimated rows;
  - COUNT and the three percentiles: five Segment / Table Spool / Stream Aggregate chains, 4,951
    executions each (about 3 s in total).
  Left for Phase 9.
- Pair rows: 279,300 = 10 x (1 + ... + 59 for sessions 3-61, plus 436 x 60 for sessions 62-497).
  4,950 sessions have at least one earlier excess return (sessions 1 and 2 have none).
- 497 rows per ticker; 61 NULL flags per ticker, first flag at session 62.
- Q1 and Q3 recomputed by interpolation (positions 15.75 and 45.25 of 60 sorted values) for VCB at
  session 300: equal to the view.
- Flags: out_1_5 288, out_3 59 sessions.
- Against |z| >= 3 (4,360 sessions with both):

  | | out_3 = 0 | out_3 = 1 |
  |---|---|---|
  | \|z\| < 3 | 4,257 | 3 |
  | \|z\| >= 3 | 44 | 56 |

- Under a normal distribution Q3 + 3 IQR is about 4.7 sd and Q3 + 1.5 IQR about 2.7 sd, so out_3 is
  stricter than |z| >= 3.
- The 3 sessions flagged by out_3 only: SHB session 118 (2025-03-18, z 2.90), TPB 131 (2025-04-04,
  z -2.99), TPB 153 (2025-05-12, z 2.60). sd / IQR of their windows: 1.24, 1.28, 1.48, against about
  0.74 under a normal distribution. Large moves inside the window widen the sd and pull z below 3;
  the quartiles are not moved by them.

- Against |z| >= 3, the 1.5 IQR fence (4,360 sessions with both):

  | | out_1_5 = 0 | out_1_5 = 1 |
  |---|---|---|
  | \|z\| < 3 | 4,072 | 188 |
  | \|z\| >= 3 | 0 | 100 |

  Every |z| >= 3 session is outside the 1.5 IQR fence; the fence adds 188 more. In this data
  |z| >= 3 sits between the two fences: looser than 3 IQR (56 of its 100 sessions), stricter
  than 1.5 IQR (all 100).

### Phase 6 summary
- Views in `sql/03_transform/600-680`, schema `mart`. Every window function partitions by `ticker`
  and orders by `session_seq`.
- Structural checks, all derived from the window definitions and all met for every ticker:
  497 rows; 1 NULL return and 1 NULL excess return (session 1); 60 NULL `corr_60` (first at
  session 61); 61 NULL z and 61 NULL IQR flags (first at session 62).
- Cross-checks by a second route: sector index from returns vs index ratio (3.3E-16); ticker index
  vs price ratio on every row (3.3E-15); excess returns sum to 0 per session (5.6E-17); correlation,
  z and quartiles recomputed by definition at sample points.
- For Limitations:
  - the sector includes each ticker at 1/10 weight, which raises the correlation of a ticker with
    the sector; z is not affected (with equal weights excess_ret = 0.9 x the leave-one-out excess);
  - z-score masking: large moves inside a 60-session window widen the sd and can pull a later
    session below |z| = 3 (3 sessions flagged by 3 IQR only, sd / IQR 1.24-1.48);
  - |z| is a distance from the last 60 sessions, not a probability: returns have fat tails
    (|z| >= 3 at 6 to 11 times the normal rate).

---

## Phase 7 - Alerts and news (from 2026-10-12)

### 7.1 Alert episodes
- `v_alert_episode` (700): alert sessions |z| >= 3 grouped into runs of consecutive sessions of one
  ticker and one direction (gaps and islands). Rules in `decisions.md` (2026-10-12).
- Sessions in episodes 100 = alert sessions 100. No two episodes of the same ticker and direction
  touch (start_seq - previous end_seq <= 1: none). Every episode is a solid run
  (sessions = end_seq - start_seq + 1 on every row).
- 96 episodes: 80 with direction +1, 16 with direction -1. All runs are one session long except
  HDB +1 (3 sessions), SHB +1 (2) and VCB +1 (2), which accounts for 100 - 96 = 4.
- Per ticker (direction -1 / +1): ACB 3 / 8, CTG 3 / 6, HDB 0 / 6, MBB 1 / 12, SHB 2 / 9,
  STB 1 / 6, TCB 0 / 9, TPB 2 / 6, VCB 3 / 9, VPB 1 / 9.
- Up-side alerts outnumber down-side alerts five to one. Recorded as an observation; the cause is not
  examined here.
- Adjacent alert sessions of opposite sign: one pair, MBB session 68 (down) and 69 (up). Splitting by
  direction makes them two episodes instead of one mixed episode; no other episode is affected.
- Checked for a bad close at MBB session 68 (2024-12-30): closes 13.10, 12.97, 13.12 for sessions
  67-69, returns -0.99% and +1.16%, sector +0.45% and -0.70%. Small moves, no sign of a wrong price.
  The z values (-3.08, +3.93) are large because MBB's excess returns over the previous 60 sessions
  were small: |z| >= 3 can come from a move of about 1% when the window is calm. Episodes keep
  sum_excess_ret so the size of the move is visible next to z. For Limitations.

### 7.2 News around episodes
- `v_episode_news` (710): one row per (episode, news item); single-bank items only
  (is_sector_news = 0), same ticker, reaction session from start_seq - 2 to end_seq + 2; LEFT JOIN
  keeps episodes without news. position by reaction session: before / during / after.
- 645 rows, 96 episodes. No row outside the window or with a sector item.
- Independent recount per episode (correlated subquery on fact_news, conditions rewritten from the
  rules) against the view, FULL JOIN: no difference. Both sides 96 episodes, 644 news rows.
- Offsets by position: before -2 to -1 from the start, during 0 from start and end, after +1 to +2
  from the end. Rows: before 211, during 146, after 287 (644 in total).
- Episodes with at least one item 95 of 96; with at least one item before or during 91;
  distinct items used 601 (644 rows: 43 rows are items inside the windows of two episodes).
- Not yet interpretable: bank news is frequent, so most 5-session windows may hold an item whatever
  the price does. A base rate for ordinary sessions is needed before reading 95 of 96 (7.3).

### 7.3 News base rate
- `sql/04_quality/720_news_base_rate.sql`: every (ticker, session) from `v_excess_zscore`, single-bank
  items per reaction session joined on (ticker, session_seq), 0 where none; 5-session window summed
  with ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING; filtered after the window to sessions with a z and a
  full window. Decision in `decisions.md` (2026-10-13).
- Sessions: alert 99, ordinary 4,241 (4,340 = 10 x (436 - 2)). One alert session falls in the last two
  sessions of its ticker and is left out for a cut window.

  | | sessions | window with >= 1 item | items per window | items on the session |
  |---|---|---|---|---|
  | alert (\|z\| >= 3) | 99 | 98.99% | 6.70 | 1.44 |
  | ordinary | 4,241 | 97.71% | 5.29 | 1.06 |

- Having news nearby does not separate alerts from ordinary sessions (99.0% vs 97.7%).
- Density does: about 27% more items in the window and 37% more on the session itself.
- Against the per-session rates from 7.2 (before ~1.10, during ~1.46, after ~1.49): items before an
  episode are at the ordinary level; items on and after the episode sessions are denser. The press
  appears to follow the price more often than it comes first. Timing only; whether the items on the
  session report the move itself is not known without reading them.
- 99 alert sessions is a small sample; no test of significance was run.
- No item lost on the session frame: single-bank items with a reaction session 5,135 in fact_news,
  5,135 after the joins and GROUP BY, 5,135 after the LEFT JOIN onto the frame; frame 4,970 rows
  (10 x 497), so the join does not multiply rows. Overall 5,135 / 4,970 = 1.03 items per session.

### 7.4 Reading the news by hand
- MBB episodes at sessions 66 (+), 68 (-) and 69 (+), end of December 2024: their windows overlap,
  so 35 rows are about 18 distinct items, mostly MBB's own filings (insider and family share trades,
  union share transfer, stock dividend issuance and ex-date, board resolutions) plus a few press
  items on partnerships (F88, Viettel). The down episode and the up episodes have nearly the same
  list: the same items cannot account for opposite moves. Filings bunch at year end on the company's
  calendar; the moves were about 1% (7.1). A coincidence in timing.
- Sample of 20 'during' items (`docs/during_sample.csv`), drawn and labelled under the rules in
  `decisions.md` (2026-10-13), title only:

  | label | items |
  |---|---|
  | a: report on the share price or trading | 4 |
  | b1: material event of the bank | 6 |
  | b2: routine or promotional | 10 |
  | c: not about the bank | 0 |

- By match tier: the 4 price reports are all tier 1 (ticker in the title, e.g. "Cổ phiếu SHB ...");
  tier 0 filings (6) and tier 2 press items (9) are all b.
- All 20 items belong to up-side episodes (80 of the 96 episodes are up-side), so the sample says
  nothing about news around down-side episodes.
- SHB session 116, the largest |z| in the data (7.62): 3 items in the sample, 2 of them report the
  shares hitting the ceiling.
- Reading: half of the items inside episodes are routine or promotional, about a third are material
  events, a fifth report the move itself, none is a wrong match. With 20 items these shares are
  indicative only.

### Phase 7 summary
- 100 alert sessions -> 96 episodes (80 up, 16 down). 95 have a single-bank item within 2 sessions,
  but so do 97.7% of ordinary sessions: having news nearby does not set episodes apart.
- Item density: 1.44 per alert session against 1.06 per ordinary session; before an episode at the
  ordinary level, on and after it about 40% higher.
- Read by hand, items inside episodes are mostly routine or promotional; a fifth report the price
  move itself. Nothing here supports a claim that news drove the moves; the timing fits the press
  following the price at least as well.

---

## Phase 8 - Data quality framework (from 2026-10-14)

### 8.1 Result tables
- Schema `dq` added to `001_create_schemas.sql`; `sql/01_ddl/500_dq_tables.sql` creates `dq.dq_run`
  and `dq.dq_check_result` only when missing, never drops them. Decision in `decisions.md`
  (2026-10-14).
- Tested inside a transaction rolled back at the end: check_status PASS for 0 failures and WARN for
  a WARN check with failures; run start and check time 0 s apart; three bad inserts rejected by
  ck_dq_result_severity (Msg 547), ck_dq_result_counts (Msg 547) and pk_dq_check_result (Msg 2627);
  no run left after the rollback. The rolled-back run used run_id 5: identity values are not
  returned by a rollback.

### 8.2 Check procedure, checks 1-5
- `sql/04_quality/800_sp_run_checks.sql`: `dq.sp_run_checks` writes a `dq_run` row, then one
  INSERT ... SELECT per check, no transaction around the run; CATCH marks the run 'failed' when the
  transaction can still be written, then rethrows.
- Clean run: 5 rows written, all PASS; checked_count 10 tickers, 4,970 fact rows, 4,970
  (ticker, date) pairs, 16 dw constraints, 497 trading sessions.
- Each check seen failing, inside a transaction rolled back afterwards:
  - constraint switched off (`ALTER TABLE ... NOCHECK CONSTRAINT ck_fact_price_daily_volume`):
    dw_constraints_trusted ERROR, 1 of 16.
  - first trading day removed from the calendar (is_trading_day = 0, session_seq = NULL; changing
    only is_trading_day is refused by ck_dim_date_session): price_on_non_trading_day 10 rows,
    price_sessions_per_ticker 10 tickers (497 against 496 expected), dim_date_session_seq_gap 496
    of 496 sessions, first sample 2024-09-27 (session_seq 2, expected 1). One missing day shifts
    every later session, so failed_count measures the symptom; the first sample key shows where
    it starts.
  - one STB session copied under the other STB ticker_key (the primary key allows it):
    price_duplicate_ticker_date 1 (STB|2024-09-26, rows=2), price_sessions_per_ticker STB=498.
  - after the rollbacks: all 5 PASS again.

### 8.2 Checks 6-8, test script
- Added return_band_within_tolerance (mart, WARN), return_band_exceeded (mart, ERROR) on
  `mart.v_return_daily`, and news_ticker_version (dw, ERROR) on `dw.fact_news`.
- `sql/04_quality/810_dq_check_tests.sql`: one block per damage, each inside a transaction rolled
  back after the run, XACT_ABORT ON, `@@TRANCOUNT` checked at the end. Only the first and last runs
  stay in the history, so dq_run ids have gaps where test runs were rolled back.
- Clean run: 8 checks written, none with checked_count 0. return_band_within_tolerance WARN with
  5 sessions (first samples HDB|2025-12-16, MBB|2025-08-14), the same count as the 5 sessions beyond
  7% and within 7.5% found in Phase 2 (2.3); return_band_exceeded 0 of 4,960 returns.
- Damage results: constraint off -> dw_constraints_trusted 1; trading day removed -> checks 1, 2, 5
  as in the first test, and the return checks see 4,950 returns (v_price_session keeps trading days
  only); STB session copied -> price_duplicate_ticker_date 1, STB=498; ACB close doubled at session
  100 -> return_band_exceeded 2 (ACB|2025-02-20 +101.18% and the session after it);
  STB news row moved to the other version -> news_ticker_version 1 (STB|301|2024-09-27).
- After all rollbacks: no open transaction, clean run again.

### 8.2 Checks 9-11 (reconciliation by key and value)
- reconcile_price_raw_stg (stg): stg values rebuilt from raw with the rules of
  `sql/02_load/100_load_stg_price.sql` (configured tickers, inside the window), TRY_CONVERT instead of
  CAST so a bad value is reported, not fatal. reconcile_price_stg_dw (dw): fact rows mapped back to
  (ticker, trade_date) through dim_ticker and dim_date. reconcile_news_stg_dw (dw): the staging pairs
  of `340_fact_news_checks.sql` query 6 against fact_news on (article_key, ticker).
- Each: EXCEPT in both directions on the key and the values, keys of both directions joined with
  UNION (a changed value counts once); checked_count = keys in the union of both sides, so
  failed_count can never exceed it.
- Clean run: 11 checks written, none with checked_count 0; the three reconciliations pass on 4,970,
  4,970 and 6,849 keys.
- Damage results (each rolled back):
  - stg close + 0.01 (ACB, 2025-07-16): reconcile_price_raw_stg 1 and reconcile_price_stg_dw 1,
    same key; stg sits between the two, so it differs from both. No band check sees a 0.01 change.
  - dw close + 0.01, same session: reconcile_price_stg_dw 1 (ACB|2025-07-16).
  - dw close doubled (block 5): return_band_exceeded 2 and reconcile_price_stg_dw 1.
  - one fact_news row deleted: reconcile_news_stg_dw 1 (CTG|1); news_ticker_version sees 6,848 rows;
    reconcile checked_count stays 6,849 (union of both sides).
  - STB news row moved to the other STB version: news_ticker_version 1, reconcile_news_stg_dw PASS
    (the pair is still (article, STB)); the two checks cover different faults.
- The whole test script (11 procedure runs) took 26 s, about 2-3 s per run of 11 checks.

### Phase 8 summary
- `dq` schema with run history (`dq_run`, `dq_check_result`), UTC times, rows only appended.
- `dq.sp_run_checks`: 11 set-based checks, no transaction around the run, a result row for every
  check even when it passes, up to 5 failing keys per check.
- Every check has been seen failing at least once on data damaged inside a rolled-back transaction
  (`810_dq_check_tests.sql`). Two checks were blind before that: a missing INSERT (the check ran and
  wrote nothing) and joins on the wrong id in sys.foreign_keys / sys.check_constraints (0 rows looked
  at, always PASS). checks_written and checked_count = 0 are now checked after every run.
- Two layers: constraints refuse bad rows on write (ck_dim_date_session refused the first damage
  script); the checks find what got in while a constraint was off, and check 4 finds the constraint
  that was off.
- Current data: all ERROR checks pass; 1 WARN, return_band_within_tolerance, 5 sessions just past 7%,
  the same 5 found in Phase 2.
- For Limitations: the reconciliations re-apply the load rules, so they catch stale or edited layers
  and partial loads, not a rule that is wrong in both the loader and the check.

