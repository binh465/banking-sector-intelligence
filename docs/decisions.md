# Decision log

One entry per decision: what, why, date. Newest at the bottom.

## 2026-09-27 - Analysis window
- Window is `(end_date - 2 years, end_date]`, stored in `config/scope.yaml`, never changed after lock.
- `end_date` = last completed HOSE session at lock time.
- `base_date` = first trading session on or after `start_date`, taken from the VNINDEX calendar, not guessed.
- Why: VCI adjusts prices retroactively, so a fixed window plus a committed raw snapshot is the only way to reproduce numbers.

## 2026-09-27 - Database collation
- `Vietnamese_100_CI_AS`; all text columns `NVARCHAR`.
- Why: news-to-ticker matching (Phase 5) compares Vietnamese bank names. Case-insensitive helps ticker matching; accent-insensitive would treat distinct syllables as equal and increase false matches.
- Known side effect: `#temp` tables take the server (tempdb) collation. Server collation is `Latin1_General_CI_AS` (checked 2026-09-27), so every `#temp` text column must declare `COLLATE DATABASE_DEFAULT`. Table variables are not affected.
- Setup note: the database first existed with the server default collation, and the create script skipped it silently. The script now THROWs on a collation mismatch; the database was dropped and rebuilt (verified: `Vietnamese_100_CI_AS`, `SIMPLE`, 4 schemas).

## 2026-09-27 - STB name change inside the window
- Ngân hàng TMCP Sài Gòn Thương Tín became Ngân hàng TMCP Sài Gòn Tài Lộc, effective 2026-06-01
  (SBV Decision 36/QĐ-QLGS4 dated 2026-06-01; approved by the AGM on 2026-04-22). Ticker STB and short name SACOMBANK unchanged.
- Source: https://www.sacombank.com.vn/trang-chu/tin-tuc/thong-bao/2026/sacombank-thong-bao-thay-doi-ten-goi.html
- Consequence: dim_ticker SCD Type 2 has one real change to model (STB gets two rows). Phase 3 still needs to
  confirm no other ticker changed its name in the window.
- Consequence for Phase 5: both names must be in the alias table; news before 2026-06-01 uses the old name.

## 2026-09-27 - CafeF per-ticker list as a recall reference
- Crawl the per-ticker endpoint (`/du-lieu/Ajax/Events_RelatedNews_New.aspx`) and keep which ticker
  each item came from (file name `{TICKER}_p{NN}.html`).
- In Phase 5, compare our title rules with this list to estimate what the rules miss. Only CafeF
  articles (`-188...chn`) are compared; disclosure pages are not in the sitemap.
- This is recall against CafeF's own tagging, not true recall. CafeF can tag by article body or tag
  wrongly. Misses get split by reading a sample of ~50: (a) the title names the bank but a rule
  didn't catch it, (b) the title doesn't name the bank at all (limit of title-only matching).

## 2026-09-27 - Company disclosures kept as a separate item type
- Disclosure pages (`/du-lieu/{TICKER}-{id}/...`) are kept, with `item_type` = article / disclosure
  and `has_time` = 0 when the listed time is `00:00`.
- How a date-only item maps to a reaction session is decided in Phase 5, after seeing how many
  there are and what they are.

## 2026-09-28 - Raw DDL creates tables only if they don't exist
- The raw DDL files used DROP + CREATE. Running one again (a tab left open in SSMS) emptied
  raw_price_daily and raw_calendar at least once without any error; the lastmod analysis then
  returned only NULL sessions. Found by row counts and sys.tables.create_date.
- Now: `IF OBJECT_ID(...) IS NULL CREATE TABLE`. Dropping is a separate, manual script
  (`sql/01_ddl/901_drop_raw_tables.sql`), used only when a table's structure changes.

## 2026-09-28 - Publish time comes from the article page, not from sitemap lastmod
- Measured on a 50-article stratified sample: lastmod lands on a different trading session
  for ~8.4% of articles (weighted), with a wide margin. Not good enough for a +-2 session match.
- Fetch the article page for every sitemap entry whose title passes `config/news_prefilter.yaml`
  (tickers, bank names, "ngân hàng"): 10,966 candidates. The wide filter is on purpose, so the
  tier-3 alias + context rule in Phase 5 still has publish times. Pages stored gzip-compressed.
- Phase 5 keeps a `time_source` column (published_time / lastmod). A matched article without a
  fetched page falls back to lastmod and is counted in Limitations.
- Known cost: some names in the filter are common words ("Tiên Phong" = pioneer,
  "Công thương" as in Bộ Công Thương), so some fetched pages are not about banks. That only costs
  fetch time; matching precision is handled in Phase 5.

## 2026-09-29 - Staging cuts prices to the locked window
- The ~100 sessions before base_date (2024-05-02 to 2024-09-25) stay in raw and are not loaded
  into staging. The window was locked in Phase 0, so every number from here on uses only that window.
- Cost: the first session (2024-09-26) has no return inside the window, and the first 60 sessions
  have no z-score. That matches the structural check planned for Phase 6 (61 rows without z per ticker).
- Raw still has the earlier sessions, so this can be changed later without downloading again.

## 2026-09-29 - Config snapshot in the database
- `ingest/load_config.py` loads `config/scope.yaml` and `config/tickers.yaml` into
  raw.raw_scope, raw.raw_ticker_config and raw.raw_ticker_name_history. SQL reads the window and
  the ticker list from there, never from hard-coded dates. config/ stays the single source.

## 2026-09-29 - Staging as real tables with primary keys
- stg.stg_price_daily (PK ticker, trade_date) and stg.stg_calendar (PK trade_date), loaded by a
  TRUNCATE + INSERT script in one transaction. A duplicate row makes the insert fail.
- Not views: a view would repeat the casting on every read and has no constraint to stop duplicates.
- Prices as DECIMAL(18,4), not float: the tick-grid test compares prices exactly. The raw check
  showed at most 2 decimals and no value that fails to convert.

## 2026-09-30 - Use VCI's adjusted prices as they are
- The tick-grid check (`price_adjustment_check.md`) shows VCI adjusts history for cash dividends
  (VCB and CTG switch to the grid at the 2026-07-23 ex-date) as well as share dividends and rights
  offerings. No move beyond 7.5%, so no large event was left unadjusted.
- So returns are computed straight from the staged closes; no own adjustment factors.
- The Limitations item "not verified whether VCI adjusts for cash dividends" is replaced by:
  prices are adjusted backwards by VCI, so a later download changes the history (Phase 4 risk),
  and the check can't see sessions with prices below 10.

## 2026-09-30 - News staging
Checked first with `040_raw_article_checks.sql` queries 6 to 10 and `020_raw_ticker_news_checks.sql`
queries 7 and 8 (results in `pipeline_log.md`, 2.4).
- stg_article keeps every sitemap URL whose publish time falls in the window, not only the pages
  fetched. Phase 5 matches on all titles, and the number of matched articles that fall back to
  lastmod can be counted for Limitations.
- A URL listed more than once (232 URLs, 25 of them with different titles): keep the row with the
  earliest lastmod and take title, lastmod and source file from that one row. This is a fixed rule,
  not a claim that the earliest lastmod is the publish time. `sitemap_rows` marks these URLs.
- Publish time: article:published_time from the page if present, else lastmod; `time_source` says
  which, `lastmod_local` is kept. The window cut uses this time. The load stops if any lastmod
  offset isn't +07:00 (the cast to datetime2 keeps the clock time and drops the offset).
- No NFC normalisation. Vietnamese_100_CI_AS compares precomposed and decomposed text as equal in
  = and LIKE (tested on one word; Phase 5 re-tests the rows that are not NFC). A binary collation,
  LEN/CHARINDEX positions, or matching in Python would still see the difference.
- stg_ticker_news: one row per ticker per URL; URL normalised to https://cafef.vn + path without
  the query string; kind from the /du-lieu/ path; 00:00 means date only for disclosures only.
- URL as VARCHAR(400) primary key: all ASCII, longest 254. A clustered key holds at most 900 bytes,
  so NVARCHAR(1000) from raw couldn't be the key. Staging joins staging only, so no implicit
  VARCHAR/NVARCHAR conversion on the key.
- article_id (digits before .chn) is kept as a second match key, not as the primary key.
  48 of 49 per-ticker articles missing by URL are in the sitemap under the same id with another slug
  (title edited, or a different slug for the same title). But 64 ids are shared by 2 or 3 different
  articles (129 URLs). So: URL stays the key; `id_url_count` is stored; matching by id is allowed
  only when id_url_count = 1.

## 2026-09-30 - Name changes in the window: STB only
- Checked for the other 9 banks: CafeF article titles and each bank's own disclosures inside the
  window (`sql/04_quality/200_rename_check.sql`), plus the licences re-issued in the window.
  - Rename articles that mention these banks are about STB, or about related companies that are not
    in scope (see below).
  - Disclosures about names are branch or transaction-office renames. Licence changes found:
    TCB licence 12/GP-NHNN of 2026-03-18 re-issues licence 38/GP-NHNN under the same name
    "Ngân hàng TMCP Kỹ thương Việt Nam"
    (https://techcombank.com/nha-dau-tu/cong-bo-thong-tin/tai-lieu-doanh-nghiep); the SHB licence
    announced on 2026-04-17 carries the same name "Ngân hàng TMCP Sài Gòn - Hà Nội"
    (https://cafef.vn/du-lieu/shb-2669352/shb-thong-bao-nhan-duoc-giay-phep-thanh-lap-va-hoat-dong-ngan-hang.chn).
    SHB launched a new brand identity at its 2026 AGM; the legal name did not change.
  - The other licence notices are titled only "thay đổi / sửa đổi / bổ sung Giấy phép" (charter
    capital, activities, or not stated). Not opened one by one. The argument that closes the gap:
    each bank's name at the end of the window (Vietstock, 2026-09-27) is the same name it had
    before the window, and no article in the window reports a rename for any of the nine.
- Result: dim_ticker SCD Type 2 has exactly one real change (STB, 2026-06-01). 10 tickers, 11 rows.
- Renamed companies close to the 10 banks, not in scope, for the Phase 5 exclusion list:
  - CBBank -> VCBNeo (Vietcombank subsidiary, from 2025-01-17). The name contains "VCB".
  - OceanBank -> MBV (MB subsidiary).
  - DongA Bank -> Vikki Bank (HDBank subsidiary, February 2025).
  - GPBank -> Ngân hàng Thương mại TNHH MTV Kỷ Nguyên Thịnh Vượng (VPBank subsidiary, approved October
    2025, short name still GPBank). The name contains "Thịnh Vượng", as does VPBank's.
  - VietinBank Securities -> Chứng khoán VietinBank (proposed late 2025); SHB Finance -> SFinance
    (September 2026, no longer an SHB subsidiary).
  - Sources: https://dantri.com.vn/kinh-doanh/ngan-hang-chuyen-giao-bat-buoc-cuoi-cung-chinh-thuc-doi-ten-20251008154851127.htm,
    https://m.cafef.vn/3-4-ngan-hang-bi-chuyen-giao-bat-buoc-da-doi-ten-vi-sao-deu-tro-thanh-ngan-hang-so-188250217113544238.chn

## 2026-10-01 - Prices revised by VCI: restate the whole ticker and log it
- VCI multiplies all earlier prices of a ticker at every corporate action (25 events in the window,
  `price_adjustment_check.md`), so a later download usually changes prices already in the warehouse.
- Appending only new sessions would mix two adjustment factors in one series and create a false
  jump at the joint, which Phase 6 would flag as an abnormal session.
- Rule in `dw.sp_load_fact_price_daily`: compare every staged session that is already in the fact.
  If any OHLCV value differs for a ticker, delete all fact rows of that ticker and insert its staged
  history again; every changed session goes to `dw.price_revision_log` (old and new values, run time).
  Exact comparison on DECIMAL, no tolerance: VCI rounds to 2 decimals and only changes a value when
  the factor changes.
- Not chosen: keeping every price version (every view and DAX measure would need a version filter;
  too heavy for ~5,000 rows), warning only (leaves the false jump in place).
- Cost: results from before a restatement can't be reproduced; the log says what changed and when.

## 2026-10-01 - Testing procedures with hand-edited staging data
- Allowed only inside one explicit transaction that covers the staging edit and the procedure runs,
  ended with ROLLBACK, so staging, dw and price_revision_log all return to their state before the
  test. Procedures therefore never commit or roll back a transaction they did not open.
- Identity values used inside a rolled-back transaction are not given back (gaps in keys and log
  ids). Harmless; noted so a gap is not mistaken for lost rows.
