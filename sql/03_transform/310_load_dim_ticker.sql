-- Load dw.dim_ticker from the config snapshot (raw.raw_ticker_config, raw.raw_ticker_name_history).
-- A ticker without name history gets one version; a ticker with history gets one per entry.
-- Full reload. TRUNCATE also resets the identity, so every reload hands out new ticker_keys: fine
-- while no fact table points here, not after. Phase 4 replaces this with a MERGE that keeps keys.
USE BankingSectorIntelligence;
GO
SET XACT_ABORT ON;

-- The last history entry (empty valid_to) must carry the same name as the current config name.
IF EXISTS (
    SELECT 1
    FROM raw.raw_ticker_name_history h
    JOIN raw.raw_ticker_config c ON c.[ticker] = h.[ticker]
    WHERE NULLIF(LTRIM(RTRIM(h.[valid_to])), N'') IS NULL
      AND LTRIM(RTRIM(h.[full_name])) <> LTRIM(RTRIM(c.[full_name])))
    THROW 50040, N'Current name in raw_ticker_name_history differs from raw_ticker_config', 1;

-- History for a ticker that isn't in the config.
IF EXISTS (SELECT 1 FROM raw.raw_ticker_name_history h
           WHERE NOT EXISTS (SELECT 1 FROM raw.raw_ticker_config c WHERE c.[ticker] = h.[ticker]))
    THROW 50041, N'raw_ticker_name_history has a ticker that is not in raw_ticker_config', 1;

BEGIN TRANSACTION;

TRUNCATE TABLE dw.dim_ticker;

WITH versions AS (
    -- tickers with name history: one row per entry
    SELECT UPPER(LTRIM(RTRIM(h.[ticker])))                                        AS ticker,
           LTRIM(RTRIM(h.[full_name]))                                            AS full_name,
           LTRIM(RTRIM(c.[exchange]))                                             AS exchange,
           COALESCE(CAST(NULLIF(LTRIM(RTRIM(h.[valid_from])), N'') AS date), '19000101') AS valid_from,
           COALESCE(CAST(NULLIF(LTRIM(RTRIM(h.[valid_to]))  , N'') AS date), '99991231') AS valid_to
    FROM raw.raw_ticker_name_history h
    JOIN raw.raw_ticker_config c ON c.[ticker] = h.[ticker]
    UNION ALL
    -- tickers without name history: the current name, valid for all time
    SELECT UPPER(LTRIM(RTRIM(c.[ticker]))), LTRIM(RTRIM(c.[full_name])), LTRIM(RTRIM(c.[exchange])),
           '19000101', '99991231'
    FROM raw.raw_ticker_config c
    WHERE NOT EXISTS (SELECT 1 FROM raw.raw_ticker_name_history h WHERE h.[ticker] = c.[ticker])
)
INSERT INTO dw.dim_ticker (ticker, full_name, exchange, valid_from, valid_to, is_current)
SELECT ticker, full_name, exchange, valid_from, valid_to,
       CASE WHEN valid_to = '99991231' THEN 1 ELSE 0 END
FROM versions
ORDER BY ticker, valid_from;   -- keys handed out in a readable order

COMMIT TRANSACTION;

SELECT ticker_key, ticker, full_name, valid_from, valid_to, is_current
FROM dw.dim_ticker ORDER BY ticker, valid_from;
GO
