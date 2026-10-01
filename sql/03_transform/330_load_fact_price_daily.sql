-- Load dw.fact_price_daily from stg.stg_price_daily.
-- ticker_key: the dim_ticker version whose valid_from..valid_to contains the session.
-- date_key: the dim_date row of the session.
-- Full reload in one transaction.
USE BankingSectorIntelligence;
GO
SET XACT_ABORT ON;

-- Each staged row must find exactly one ticker version; zero would drop the row in the join,
-- two would duplicate it.
IF EXISTS (
    SELECT 1
    FROM stg.stg_price_daily p
    LEFT JOIN dw.dim_ticker t ON t.ticker = p.ticker AND p.trade_date BETWEEN t.valid_from AND t.valid_to
    GROUP BY p.ticker, p.trade_date
    HAVING COUNT(t.ticker_key) <> 1)
    THROW 50060, N'A staged price row matches zero or several dim_ticker versions', 1;

-- Each staged session must be a trading day in dim_date.
IF EXISTS (SELECT 1 FROM stg.stg_price_daily p
           WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date d
                             WHERE d.full_date = p.trade_date AND d.is_trading_day = 1))
    THROW 50061, N'A staged price date is not a trading day in dim_date', 1;

BEGIN TRANSACTION;

TRUNCATE TABLE dw.fact_price_daily;

INSERT INTO dw.fact_price_daily (ticker_key, date_key, open_price, high_price, low_price, close_price, volume)
SELECT t.ticker_key, d.date_key, p.open_price, p.high_price, p.low_price, p.close_price, p.volume
FROM stg.stg_price_daily p
JOIN dw.dim_ticker t ON t.ticker = p.ticker AND p.trade_date BETWEEN t.valid_from AND t.valid_to
JOIN dw.dim_date   d ON d.full_date = p.trade_date;

COMMIT TRANSACTION;

SELECT (SELECT COUNT(*) FROM stg.stg_price_daily) AS stg_rows,
       (SELECT COUNT(*) FROM dw.fact_price_daily) AS fact_rows;
GO
