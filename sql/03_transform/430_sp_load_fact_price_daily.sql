-- dw.sp_load_fact_price_daily: load staged prices into dw.fact_price_daily, incrementally.
-- @to_date: last session to load for tickers without revisions (NULL = everything staged). Used to
--           test incremental loading by splitting the window into two runs.
-- Steps, in one transaction:
--   1. re-key: a fact row whose ticker_key is no longer the version valid on its date gets the
--      right key (after a new dim_ticker version)
--   2. revisions: staged sessions already in the fact with any different OHLCV value are written to
--      dw.price_revision_log
--   3. restatement: every ticker with a revision loses all its fact rows (decisions.md, 2026-10-01);
--      step 4 inserts its staged history again, ignoring @to_date, so the series never mixes factors
--   4. insert: staged sessions not yet in the fact
-- Needs dim_date and dim_ticker loaded first. Same transaction rule as sp_load_dim_date.
USE BankingSectorIntelligence;
GO

CREATE OR ALTER PROCEDURE dw.sp_load_fact_price_daily
    @to_date DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @run_at  DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @cut     DATE = COALESCE(@to_date, '99991231');

    IF EXISTS (SELECT 1
               FROM stg.stg_price_daily p
               LEFT JOIN dw.dim_ticker t ON t.ticker = p.ticker AND p.trade_date BETWEEN t.valid_from AND t.valid_to
               GROUP BY p.ticker, p.trade_date
               HAVING COUNT(t.ticker_key) <> 1)
        THROW 50060, N'A staged price row matches zero or several dim_ticker versions', 1;
    IF EXISTS (SELECT 1 FROM stg.stg_price_daily p
               WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date d WHERE d.full_date = p.trade_date AND d.is_trading_day = 1))
        THROW 50061, N'A staged price date is not a trading day in dim_date', 1;

    -- Staged rows with their keys. Temp tables take tempdb's collation (Latin1 on this server), so
    -- the text column is declared with the database collation.
    CREATE TABLE #s (
        ticker      NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL,
        trade_date  DATE           NOT NULL,
        ticker_key  INT            NOT NULL,
        date_key    INT            NOT NULL,
        open_price  DECIMAL(18,4)  NOT NULL,
        high_price  DECIMAL(18,4)  NOT NULL,
        low_price   DECIMAL(18,4)  NOT NULL,
        close_price DECIMAL(18,4)  NOT NULL,
        volume      BIGINT         NOT NULL,
        PRIMARY KEY (ticker_key, date_key)
    );
    INSERT INTO #s
    SELECT p.ticker, p.trade_date, t.ticker_key, d.date_key,
           p.open_price, p.high_price, p.low_price, p.close_price, p.volume
    FROM stg.stg_price_daily p
    JOIN dw.dim_ticker t ON t.ticker = p.ticker AND p.trade_date BETWEEN t.valid_from AND t.valid_to
    JOIN dw.dim_date   d ON d.full_date = p.trade_date;

    DECLARE @own_tran bit = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    DECLARE @rekeyed INT, @revised INT, @deleted INT, @inserted INT;
    DECLARE @revised_rows TABLE (ticker NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL);
    DECLARE @restated     TABLE (ticker NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);

    BEGIN TRY
        IF @own_tran = 1 BEGIN TRANSACTION;

        -- 1. re-key
        UPDATE f
           SET f.ticker_key = t_new.ticker_key
        FROM dw.fact_price_daily f
        JOIN dw.dim_ticker t_old ON t_old.ticker_key = f.ticker_key
        JOIN dw.dim_date   d     ON d.date_key = f.date_key
        JOIN dw.dim_ticker t_new ON t_new.ticker = t_old.ticker
                                AND d.full_date BETWEEN t_new.valid_from AND t_new.valid_to
        WHERE t_new.ticker_key <> f.ticker_key;
        SET @rekeyed = @@ROWCOUNT;

        -- 2. revisions
        INSERT INTO dw.price_revision_log (run_at_utc, ticker, trade_date,
                                           old_open, old_high, old_low, old_close, old_volume,
                                           new_open, new_high, new_low, new_close, new_volume)
        OUTPUT inserted.ticker INTO @revised_rows (ticker)
        SELECT @run_at, s.ticker, s.trade_date,
               f.open_price, f.high_price, f.low_price, f.close_price, f.volume,
               s.open_price, s.high_price, s.low_price, s.close_price, s.volume
        FROM #s s
        JOIN dw.fact_price_daily f ON f.ticker_key = s.ticker_key AND f.date_key = s.date_key
        WHERE EXISTS (SELECT f.open_price, f.high_price, f.low_price, f.close_price, f.volume
                      EXCEPT
                      SELECT s.open_price, s.high_price, s.low_price, s.close_price, s.volume);
        SET @revised = @@ROWCOUNT;

        INSERT INTO @restated (ticker)
        SELECT DISTINCT ticker FROM @revised_rows;

        -- 3. restatement: remove every version's rows of a revised ticker
        DELETE f
        FROM dw.fact_price_daily f
        JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
        WHERE t.ticker IN (SELECT ticker FROM @restated);
        SET @deleted = @@ROWCOUNT;

        -- 4. insert what is missing: new sessions up to @cut, and the full history of restated tickers
        INSERT INTO dw.fact_price_daily (ticker_key, date_key, open_price, high_price, low_price, close_price, volume)
        SELECT s.ticker_key, s.date_key, s.open_price, s.high_price, s.low_price, s.close_price, s.volume
        FROM #s s
        WHERE (s.trade_date <= @cut OR s.ticker IN (SELECT ticker FROM @restated))
          AND NOT EXISTS (SELECT 1 FROM dw.fact_price_daily f
                          WHERE f.ticker_key = s.ticker_key AND f.date_key = s.date_key);
        SET @inserted = @@ROWCOUNT;

        IF @own_tran = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own_tran = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT N'fact_price_daily'                  AS tbl,
           @rekeyed                             AS rekeyed,
           @revised                             AS revised_sessions,
           (SELECT COUNT(*) FROM @restated)     AS restated_tickers,
           @deleted                             AS deleted_for_restatement,
           @inserted                            AS inserted,
           (SELECT COUNT(*) FROM dw.fact_price_daily f
             WHERE NOT EXISTS (SELECT 1 FROM #s s WHERE s.ticker_key = f.ticker_key AND s.date_key = f.date_key)
           )                                    AS fact_rows_not_in_staging;
END;
GO
