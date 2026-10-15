-- Tests for dq.sp_run_checks (sql/04_quality/800_sp_run_checks.sql). Run 800 first.
-- Each block damages dw data inside a transaction, runs the checks and rolls back, so the damage and
-- the dq_run / dq_check_result rows of that run are both undone. Only blocks 0 and 10 leave a run in
-- the history.
-- XACT_ABORT ON: if anything inside a block fails, the whole block is rolled back instead of leaving
-- a transaction open.
USE BankingSectorIntelligence;
GO
SET XACT_ABORT ON;
GO

-------------------------------------------------------------------- 0. clean run
EXEC dq.sp_run_checks;

-- one row per check in every run, and no check that looked at nothing
SELECT r.run_id, r.run_status, COUNT(c.check_name) AS checks_written,
       SUM(CASE WHEN c.checked_count = 0 THEN 1 ELSE 0 END) AS checks_that_saw_nothing
FROM dq.dq_run r
LEFT JOIN dq.dq_check_result c ON c.run_id = r.run_id
GROUP BY r.run_id, r.run_status
ORDER BY r.run_id DESC;
GO

-------------------------------------------------------------------- 1. constraint blocks the damage
-- Not a test of the checks: changing is_trading_day alone is refused by ck_dim_date_session
-- (Msg 547), so no check ever sees that state. Left commented out; run it by hand to see the refusal.
-- BEGIN TRANSACTION;
-- UPDATE dw.dim_date SET is_trading_day = 0
-- WHERE date_key = (SELECT MIN(date_key) FROM dw.dim_date WHERE is_trading_day = 1);
-- ROLLBACK TRANSACTION;
GO

-------------------------------------------------------------------- 2. check 4: a constraint switched off
BEGIN TRANSACTION;
ALTER TABLE dw.fact_price_daily NOCHECK CONSTRAINT ck_fact_price_daily_volume;
EXEC dq.sp_run_checks;
ROLLBACK TRANSACTION;
GO

-------------------------------------------------------------------- 3. checks 1, 2, 5: a trading day removed from the calendar, its prices kept
BEGIN TRANSACTION;
UPDATE dw.dim_date SET is_trading_day = 0, session_seq = NULL
WHERE date_key = (SELECT MIN(date_key) FROM dw.dim_date WHERE is_trading_day = 1);
EXEC dq.sp_run_checks;
ROLLBACK TRANSACTION;
GO

-------------------------------------------------------------------- 4. check 3: one STB session loaded under both ticker_key versions
BEGIN TRANSACTION;
DECLARE @k1 INT, @k2 INT;
SELECT @k1 = MIN(ticker_key), @k2 = MAX(ticker_key) FROM dw.dim_ticker WHERE ticker = 'STB';
INSERT INTO dw.fact_price_daily (ticker_key, date_key, open_price, high_price, low_price, close_price, volume)
SELECT TOP (1) CASE WHEN f.ticker_key = @k1 THEN @k2 ELSE @k1 END,
       f.date_key, f.open_price, f.high_price, f.low_price, f.close_price, f.volume
FROM dw.fact_price_daily f
WHERE f.ticker_key IN (@k1, @k2)
ORDER BY f.date_key;
EXEC dq.sp_run_checks;
ROLLBACK TRANSACTION;
GO

-------------------------------------------------------------------- 5. check 7: one close doubled
-- high_price is raised with it: ck_fact_price_daily_prices needs close between low and high.
-- Both SET expressions read the values from before the update.
BEGIN TRANSACTION;
UPDATE f
SET close_price = f.close_price * 2, high_price = f.close_price * 2
FROM dw.fact_price_daily f
WHERE f.ticker_key = (SELECT MIN(ticker_key) FROM dw.dim_ticker WHERE ticker = 'ACB')
  AND f.date_key   = (SELECT date_key FROM dw.dim_date WHERE session_seq = 100);
EXEC dq.sp_run_checks;
ROLLBACK TRANSACTION;
GO

-------------------------------------------------------------------- 6. check 8: one STB news row moved to the other STB version
BEGIN TRANSACTION;
DECLARE @s1 INT, @s2 INT;
SELECT @s1 = MIN(ticker_key), @s2 = MAX(ticker_key) FROM dw.dim_ticker WHERE ticker = 'STB';
UPDATE TOP (1) dw.fact_news
SET ticker_key = CASE WHEN ticker_key = @s1 THEN @s2 ELSE @s1 END
WHERE ticker_key IN (@s1, @s2);
EXEC dq.sp_run_checks;
ROLLBACK TRANSACTION;
GO

-------------------------------------------------------------------- 7. checks 9, 10: one stg close changed
-- stg sits between raw and dw, so a change there differs from both neighbours.
BEGIN TRANSACTION;
UPDATE s
SET close_price = s.close_price + 0.01
FROM stg.stg_price_daily s
WHERE s.ticker = 'ACB'
  AND s.trade_date = (SELECT full_date FROM dw.dim_date WHERE session_seq = 200);
EXEC dq.sp_run_checks;
ROLLBACK TRANSACTION;
GO

-------------------------------------------------------------------- 8. check 10: one dw close changed
-- high_price moves with it so ck_fact_price_daily_prices still holds.
BEGIN TRANSACTION;
UPDATE f
SET close_price = f.close_price + 0.01, high_price = f.high_price + 0.01
FROM dw.fact_price_daily f
WHERE f.ticker_key = (SELECT MIN(ticker_key) FROM dw.dim_ticker WHERE ticker = 'ACB')
  AND f.date_key   = (SELECT date_key FROM dw.dim_date WHERE session_seq = 200);
EXEC dq.sp_run_checks;
ROLLBACK TRANSACTION;
GO

-------------------------------------------------------------------- 9. check 11: one fact_news row missing
BEGIN TRANSACTION;
DELETE TOP (1) FROM dw.fact_news;
EXEC dq.sp_run_checks;
ROLLBACK TRANSACTION;
GO

-------------------------------------------------------------------- 10. after all rollbacks
-- No transaction may be left open, and a clean run again.
SELECT @@TRANCOUNT AS open_transactions;
EXEC dq.sp_run_checks;
GO
