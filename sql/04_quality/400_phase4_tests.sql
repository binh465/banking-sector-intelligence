-- Phase 4 tests for the load procedures. Run the whole file in one SSMS window (one session).
-- Every test runs inside its own transaction and ends with ROLLBACK, so staging, raw config, dw and
-- price_revision_log return to their state before the test (decisions.md, 2026-10-01).
-- Test 0 takes a snapshot of the state; test 5 compares the state after all tests with it.
-- Each test is its own batch: with XACT_ABORT ON, an error rolls back that test's transaction and
-- stops only that batch.
USE BankingSectorIntelligence;
GO
SET XACT_ABORT ON;
SET NOCOUNT ON;
GO

-- 0. Snapshot of the state before the tests.
IF OBJECT_ID(N'tempdb..#state_before') IS NOT NULL DROP TABLE #state_before;
SELECT N'fact_price_daily' AS tbl, COUNT(*) AS n,
       CHECKSUM_AGG(BINARY_CHECKSUM(ticker_key, date_key, open_price, high_price, low_price, close_price, volume)) AS chk
INTO #state_before
FROM dw.fact_price_daily
UNION ALL
SELECT N'dim_ticker', COUNT(*),
       CHECKSUM_AGG(BINARY_CHECKSUM(ticker_key, ticker, full_name, valid_from, valid_to, is_current))
FROM dw.dim_ticker
UNION ALL
SELECT N'stg_price_daily', COUNT(*),
       CHECKSUM_AGG(BINARY_CHECKSUM(ticker, trade_date, open_price, high_price, low_price, close_price, volume))
FROM stg.stg_price_daily
UNION ALL
SELECT N'raw_ticker_config', COUNT(*), CHECKSUM_AGG(BINARY_CHECKSUM(ticker, full_name, exchange))
FROM raw.raw_ticker_config
UNION ALL
SELECT N'raw_ticker_name_history', COUNT(*), CHECKSUM_AGG(BINARY_CHECKSUM(ticker, full_name, valid_from, valid_to))
FROM raw.raw_ticker_name_history
UNION ALL
SELECT N'price_revision_log', COUNT(*), CHECKSUM_AGG(BINARY_CHECKSUM(revision_id))
FROM dw.price_revision_log;
SELECT * FROM #state_before ORDER BY tbl;
GO

-- 1. Run every procedure twice in a row. Each result set counts what the run changed.
BEGIN TRANSACTION;
    PRINT N'--- test 1, run 1';
    EXEC dw.sp_load_dim_date;
    EXEC dw.sp_load_dim_ticker;
    EXEC dw.sp_load_dim_article;
    EXEC dw.sp_load_fact_price_daily;
    PRINT N'--- test 1, run 2';
    EXEC dw.sp_load_dim_date;
    EXEC dw.sp_load_dim_ticker;
    EXEC dw.sp_load_dim_article;
    EXEC dw.sp_load_fact_price_daily;
ROLLBACK TRANSACTION;
GO

-- 2. Incremental load: empty the fact, load sessions up to 2025-09-30, then the rest.
--    Compare the result with staging in both directions.
BEGIN TRANSACTION;
    TRUNCATE TABLE dw.fact_price_daily;

    EXEC dw.sp_load_fact_price_daily @to_date = '2025-09-30';
    SELECT N'after run 1' AS step, COUNT(*) AS fact_rows, MAX(d.full_date) AS last_date
    FROM dw.fact_price_daily f JOIN dw.dim_date d ON d.date_key = f.date_key;

    EXEC dw.sp_load_fact_price_daily;
    SELECT N'after run 2' AS step, COUNT(*) AS fact_rows, MAX(d.full_date) AS last_date
    FROM dw.fact_price_daily f JOIN dw.dim_date d ON d.date_key = f.date_key;

    SELECT N'stg not in fact' AS side, COUNT(*) AS n
    FROM (SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume FROM stg.stg_price_daily
          EXCEPT
          SELECT t.ticker, d.full_date, f.open_price, f.high_price, f.low_price, f.close_price, f.volume
          FROM dw.fact_price_daily f
          JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
          JOIN dw.dim_date   d ON d.date_key   = f.date_key) x
    UNION ALL
    SELECT N'fact not in stg', COUNT(*)
    FROM (SELECT t.ticker, d.full_date, f.open_price, f.high_price, f.low_price, f.close_price, f.volume
          FROM dw.fact_price_daily f
          JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
          JOIN dw.dim_date   d ON d.date_key   = f.date_key
          EXCEPT
          SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume FROM stg.stg_price_daily) y;
ROLLBACK TRANSACTION;
GO

-- 3. Revised prices: multiply VCB's staged prices before 2026-03-02 by 0.98 (as a new adjustment
--    would), run the fact load, look at the log and at VCB in the fact.
BEGIN TRANSACTION;
    UPDATE stg.stg_price_daily
       SET open_price  = ROUND(open_price  * 0.98, 2),
           high_price  = ROUND(high_price  * 0.98, 2),
           low_price   = ROUND(low_price   * 0.98, 2),
           close_price = ROUND(close_price * 0.98, 2)
     WHERE ticker = N'VCB' AND trade_date < '2026-03-02';
    SELECT N'staged sessions edited' AS step, @@ROWCOUNT AS n;

    EXEC dw.sp_load_fact_price_daily;

    -- rows written by this run (the latest run_at_utc)
    SELECT ticker, COUNT(*) AS logged_sessions, MIN(trade_date) AS first_date, MAX(trade_date) AS last_date
    FROM dw.price_revision_log
    WHERE run_at_utc = (SELECT MAX(run_at_utc) FROM dw.price_revision_log)
    GROUP BY ticker;

    SELECT TOP (3) ticker, trade_date, old_close, new_close
    FROM dw.price_revision_log
    WHERE run_at_utc = (SELECT MAX(run_at_utc) FROM dw.price_revision_log)
    ORDER BY trade_date;

    -- VCB in the fact now equals the edited staging; other tickers untouched.
    SELECT t.ticker,
           SUM(CASE WHEN f.close_price = s.close_price THEN 1 ELSE 0 END) AS close_equal_to_stg,
           COUNT(*) AS fact_rows
    FROM dw.fact_price_daily f
    JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
    JOIN dw.dim_date   d ON d.date_key   = f.date_key
    JOIN stg.stg_price_daily s ON s.ticker = t.ticker AND s.trade_date = d.full_date
    GROUP BY t.ticker
    ORDER BY t.ticker;
ROLLBACK TRANSACTION;
GO

-- 4. A new rename (SCD2): pretend VCB changes its name from 2026-07-01. Edit the raw config the way
--    load_config.py would write it, run dim_ticker then the fact load.
BEGIN TRANSACTION;
    DECLARE @old_name NVARCHAR(400) = (SELECT full_name FROM raw.raw_ticker_config WHERE ticker = N'VCB');

    UPDATE raw.raw_ticker_config SET full_name = N'Ngân hàng TMCP Thử Nghiệm' WHERE ticker = N'VCB';
    INSERT INTO raw.raw_ticker_name_history (ticker, full_name, valid_from, valid_to, name_change_source, source_file)
    VALUES (N'VCB', @old_name,                    N'',           N'2026-06-30', N'test', N'test'),
           (N'VCB', N'Ngân hàng TMCP Thử Nghiệm', N'2026-07-01', N'',           N'test', N'test');

    EXEC dw.sp_load_dim_ticker;
    EXEC dw.sp_load_fact_price_daily;

    SELECT ticker_key, ticker, full_name, valid_from, valid_to, is_current
    FROM dw.dim_ticker WHERE ticker = N'VCB' ORDER BY valid_from;

    SELECT f.ticker_key, COUNT(*) AS fact_rows, MIN(d.full_date) AS first_date, MAX(d.full_date) AS last_date
    FROM dw.fact_price_daily f
    JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
    JOIN dw.dim_date   d ON d.date_key   = f.date_key
    WHERE t.ticker = N'VCB'
    GROUP BY f.ticker_key
    ORDER BY f.ticker_key;

    -- grain still holds: one row per ticker per session
    SELECT t.ticker, f.date_key, COUNT(*) AS n
    FROM dw.fact_price_daily f JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
    GROUP BY t.ticker, f.date_key HAVING COUNT(*) > 1;
ROLLBACK TRANSACTION;
GO

-- 5. State after all tests vs the snapshot: every row must show same_n = 1 and same_chk = 1.
WITH after_state AS (
    SELECT N'fact_price_daily' AS tbl, COUNT(*) AS n,
           CHECKSUM_AGG(BINARY_CHECKSUM(ticker_key, date_key, open_price, high_price, low_price, close_price, volume)) AS chk
    FROM dw.fact_price_daily
    UNION ALL
    SELECT N'dim_ticker', COUNT(*),
           CHECKSUM_AGG(BINARY_CHECKSUM(ticker_key, ticker, full_name, valid_from, valid_to, is_current))
    FROM dw.dim_ticker
    UNION ALL
    SELECT N'stg_price_daily', COUNT(*),
           CHECKSUM_AGG(BINARY_CHECKSUM(ticker, trade_date, open_price, high_price, low_price, close_price, volume))
    FROM stg.stg_price_daily
    UNION ALL
    SELECT N'raw_ticker_config', COUNT(*), CHECKSUM_AGG(BINARY_CHECKSUM(ticker, full_name, exchange))
    FROM raw.raw_ticker_config
    UNION ALL
    SELECT N'raw_ticker_name_history', COUNT(*), CHECKSUM_AGG(BINARY_CHECKSUM(ticker, full_name, valid_from, valid_to))
    FROM raw.raw_ticker_name_history
    UNION ALL
    SELECT N'price_revision_log', COUNT(*), CHECKSUM_AGG(BINARY_CHECKSUM(revision_id))
    FROM dw.price_revision_log
)
SELECT b.tbl, b.n AS n_before, a.n AS n_after,
       CASE WHEN b.n = a.n THEN 1 ELSE 0 END AS same_n,
       CASE WHEN b.chk = a.chk OR (b.chk IS NULL AND a.chk IS NULL) THEN 1 ELSE 0 END AS same_chk
FROM #state_before b
JOIN after_state a ON a.tbl = b.tbl
ORDER BY b.tbl;
GO
