-- Load stg_scope, stg_calendar and stg_price_daily from the raw layer.
-- Full reload in one transaction: any error rolls back everything (XACT_ABORT).
-- CAST, not TRY_CONVERT: the raw values were checked first, so a value that doesn't convert
-- now means the data changed, and the load should stop instead of writing NULL.
USE BankingSectorIntelligence;
GO
SET XACT_ABORT ON;

-- Casting the raw time to date drops the time of day. Stop if any time isn't midnight,
-- instead of cutting it off without a word.
IF EXISTS (SELECT 1 FROM raw.raw_price_daily
           WHERE CAST(CAST([time] AS datetime2(0)) AS time) <> '00:00:00')
    THROW 50011, N'raw.raw_price_daily has a time that is not midnight - casting to date would lose it', 1;
IF EXISTS (SELECT 1 FROM raw.raw_calendar
           WHERE CAST(CAST([time] AS datetime2(0)) AS time) <> '00:00:00')
    THROW 50012, N'raw.raw_calendar has a time that is not midnight - casting to date would lose it', 1;

BEGIN TRANSACTION;

TRUNCATE TABLE stg.stg_price_daily;
TRUNCATE TABLE stg.stg_calendar;
TRUNCATE TABLE stg.stg_scope;

INSERT INTO stg.stg_scope (start_date, end_date, base_date)
SELECT CAST([start_date] AS date), CAST([end_date] AS date), CAST([base_date] AS date)
FROM raw.raw_scope;

IF (SELECT COUNT(*) FROM stg.stg_scope) <> 1
    THROW 50010, N'raw.raw_scope must hold exactly one row - run ingest/load_config.py', 1;

INSERT INTO stg.stg_calendar (trade_date, open_index, high_index, low_index, close_index, volume, downloaded_at_utc)
SELECT d.trade_date,
       CAST(c.[open]  AS decimal(18,4)),
       CAST(c.[high]  AS decimal(18,4)),
       CAST(c.[low]   AS decimal(18,4)),
       CAST(c.[close] AS decimal(18,4)),
       CAST(c.[volume] AS bigint),
       CAST(CAST(c.[downloaded_at_utc] AS datetimeoffset(0)) AS datetime2(0))
FROM raw.raw_calendar c
CROSS APPLY (SELECT CAST(CAST(c.[time] AS datetime2(0)) AS date) AS trade_date) d
CROSS JOIN stg.stg_scope s
WHERE d.trade_date BETWEEN s.start_date AND s.end_date;

INSERT INTO stg.stg_price_daily (ticker, trade_date, open_price, high_price, low_price, close_price,
                                 volume, source, vnstock_version, downloaded_at_utc)
SELECT t.ticker,
       d.trade_date,
       CAST(p.[open]  AS decimal(18,4)),
       CAST(p.[high]  AS decimal(18,4)),
       CAST(p.[low]   AS decimal(18,4)),
       CAST(p.[close] AS decimal(18,4)),
       CAST(p.[volume] AS bigint),
       LTRIM(RTRIM(p.[source])),
       LTRIM(RTRIM(p.[vnstock_version])),
       CAST(CAST(p.[downloaded_at_utc] AS datetimeoffset(0)) AS datetime2(0))
FROM raw.raw_price_daily p
CROSS APPLY (SELECT UPPER(LTRIM(RTRIM(p.[symbol]))) AS ticker,
                    CAST(CAST(p.[time] AS datetime2(0)) AS date) AS trade_date) d
-- Only tickers in config/tickers.yaml. A symbol in raw that isn't in the config is left out on
-- purpose; check 4 in sql/04_quality/100_stg_price_checks.sql shows it as raw rows with no stg rows.
JOIN raw.raw_ticker_config t ON t.[ticker] = d.ticker
CROSS JOIN stg.stg_scope s
WHERE d.trade_date BETWEEN s.start_date AND s.end_date;

COMMIT TRANSACTION;

SELECT N'stg_calendar' AS tbl, COUNT(*) AS n FROM stg.stg_calendar
UNION ALL SELECT N'stg_price_daily', COUNT(*) FROM stg.stg_price_daily;
GO
