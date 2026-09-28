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
