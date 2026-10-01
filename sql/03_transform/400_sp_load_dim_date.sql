-- dw.sp_load_dim_date: sync dw.dim_date with stg.stg_scope and stg.stg_calendar.
-- MERGE instead of TRUNCATE: dim_date is referenced by foreign keys, and keys must not change.
--   new date            -> insert
--   changed attributes  -> update (e.g. a session added to or removed from the calendar)
--   date outside window -> not deleted by MERGE; the procedure stops before it (facts may point there)
-- Transactions: opens its own only when called outside one; inside a caller's transaction it neither
-- commits nor rolls back (decisions.md, 2026-10-01).
USE BankingSectorIntelligence;
GO

CREATE OR ALTER PROCEDURE dw.sp_load_dim_date
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF (SELECT COUNT(*) FROM stg.stg_scope) <> 1
        THROW 50030, N'stg.stg_scope must hold exactly one row', 1;
    IF EXISTS (SELECT 1 FROM stg.stg_calendar c CROSS JOIN stg.stg_scope s
               WHERE c.trade_date NOT BETWEEN s.start_date AND s.end_date)
        THROW 50032, N'stg.stg_calendar has a session outside the window', 1;
    IF EXISTS (SELECT 1 FROM dw.dim_date d CROSS JOIN stg.stg_scope s
               WHERE d.full_date NOT BETWEEN s.start_date AND s.end_date)
        THROW 50033, N'dw.dim_date has a date outside the window - the window was locked in Phase 0', 1;

    DECLARE @own_tran bit = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    DECLARE @actions TABLE (act NVARCHAR(10));

    BEGIN TRY
        IF @own_tran = 1 BEGIN TRANSACTION;

        WITH d AS (
            SELECT DATEADD(day, g.value, s.start_date) AS full_date
            FROM stg.stg_scope s
            CROSS APPLY GENERATE_SERIES(0, DATEDIFF(day, s.start_date, s.end_date)) g
        ),
        t AS (
            SELECT d.full_date, CASE WHEN c.trade_date IS NOT NULL THEN 1 ELSE 0 END AS is_trading_day
            FROM d LEFT JOIN stg.stg_calendar c ON c.trade_date = d.full_date
        ),
        src AS (
            SELECT YEAR(t.full_date) * 10000 + MONTH(t.full_date) * 100 + DAY(t.full_date) AS date_key,
                   t.full_date,
                   CAST(YEAR(t.full_date) AS smallint)                                 AS [year],
                   CAST(DATEPART(quarter, t.full_date) AS tinyint)                     AS [quarter],
                   CAST(MONTH(t.full_date) AS tinyint)                                 AS [month],
                   DATEFROMPARTS(YEAR(t.full_date), MONTH(t.full_date), 1)             AS month_start,
                   CAST(DAY(t.full_date) AS tinyint)                                   AS day_of_month,
                   CAST(DATEPART(iso_week, t.full_date) AS tinyint)                    AS iso_week,
                   CAST(DATEDIFF(day, '19000101', t.full_date) % 7 + 1 AS tinyint)     AS day_of_week,
                   CAST(CASE WHEN DATEDIFF(day, '19000101', t.full_date) % 7 >= 5 THEN 1 ELSE 0 END AS bit) AS is_weekend,
                   CAST(t.is_trading_day AS bit)                                       AS is_trading_day,
                   CAST(CASE WHEN t.is_trading_day = 1
                             THEN ROW_NUMBER() OVER (PARTITION BY t.is_trading_day ORDER BY t.full_date) END AS smallint) AS session_seq
            FROM t
        )
        MERGE dw.dim_date WITH (HOLDLOCK) AS tgt
        USING src
           ON tgt.date_key = src.date_key
        WHEN MATCHED AND EXISTS (SELECT tgt.is_trading_day, tgt.session_seq, tgt.full_date
                                 EXCEPT
                                 SELECT src.is_trading_day, src.session_seq, src.full_date)
            THEN UPDATE SET tgt.is_trading_day = src.is_trading_day,
                            tgt.session_seq    = src.session_seq
        WHEN NOT MATCHED BY TARGET
            THEN INSERT (date_key, full_date, [year], [quarter], [month], month_start, day_of_month,
                         iso_week, day_of_week, is_weekend, is_trading_day, session_seq)
                 VALUES (src.date_key, src.full_date, src.[year], src.[quarter], src.[month], src.month_start,
                         src.day_of_month, src.iso_week, src.day_of_week, src.is_weekend,
                         src.is_trading_day, src.session_seq)
        OUTPUT $action INTO @actions;

        IF @own_tran = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @own_tran = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT N'dim_date' AS tbl,
           COUNT(CASE WHEN act = N'INSERT' THEN 1 END)   AS inserted,
           COUNT(CASE WHEN act = N'UPDATE' THEN 1 END)   AS updated
    FROM @actions;
END;
GO
