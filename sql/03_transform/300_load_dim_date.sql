-- Load dw.dim_date from stg.stg_scope (the window) and stg.stg_calendar (the sessions).
-- Full reload in one transaction. TRUNCATE stops working once a fact table has a foreign key to
-- dim_date; Phase 4 replaces this script with a procedure.
USE BankingSectorIntelligence;
GO
SET XACT_ABORT ON;

IF (SELECT COUNT(*) FROM stg.stg_scope) <> 1
    THROW 50030, N'stg.stg_scope must hold exactly one row - run 100_load_stg_price.sql first', 1;

-- GENERATE_SERIES needs database compatibility level 160 or higher.
IF (SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME()) < 160
    THROW 50031, N'GENERATE_SERIES needs compatibility level 160 or higher', 1;

-- A session outside the window would never get a row here.
IF EXISTS (SELECT 1 FROM stg.stg_calendar c CROSS JOIN stg.stg_scope s
           WHERE c.trade_date NOT BETWEEN s.start_date AND s.end_date)
    THROW 50032, N'stg.stg_calendar has a session outside the window', 1;

BEGIN TRANSACTION;

TRUNCATE TABLE dw.dim_date;

-- d: every calendar day from start_date to end_date (0 .. number of days).
-- t: flag the days that are sessions.
-- q: number the sessions. PARTITION BY is_trading_day gives the trading days their own 1..n;
--    the CASE blanks the numbers the non-trading partition also gets.
WITH d AS (
    SELECT DATEADD(day, g.value, s.start_date) AS full_date
    FROM stg.stg_scope s
    CROSS APPLY GENERATE_SERIES(0, DATEDIFF(day, s.start_date, s.end_date)) g
),
t AS (
    SELECT d.full_date,
           CASE WHEN c.trade_date IS NOT NULL THEN 1 ELSE 0 END AS is_trading_day
    FROM d
    LEFT JOIN stg.stg_calendar c ON c.trade_date = d.full_date
),
q AS (
    SELECT t.full_date, t.is_trading_day,
           CASE WHEN t.is_trading_day = 1
                THEN ROW_NUMBER() OVER (PARTITION BY t.is_trading_day ORDER BY t.full_date) END AS session_seq
    FROM t
)
INSERT INTO dw.dim_date (date_key, full_date, [year], [quarter], [month], month_start, day_of_month,
                         iso_week, day_of_week, is_weekend, is_trading_day, session_seq)
SELECT YEAR(q.full_date) * 10000 + MONTH(q.full_date) * 100 + DAY(q.full_date),
       q.full_date,
       YEAR(q.full_date),
       DATEPART(quarter, q.full_date),
       MONTH(q.full_date),
       DATEFROMPARTS(YEAR(q.full_date), MONTH(q.full_date), 1),
       DAY(q.full_date),
       DATEPART(iso_week, q.full_date),
       w.day_of_week,
       CASE WHEN w.day_of_week >= 6 THEN 1 ELSE 0 END,
       q.is_trading_day,
       q.session_seq
FROM q
-- 1900-01-01 was a Monday, so days since then mod 7 gives 0 = Monday. DATEPART(weekday) would
-- depend on SET DATEFIRST, which differs between logins and languages.
CROSS APPLY (SELECT DATEDIFF(day, '19000101', q.full_date) % 7 + 1 AS day_of_week) w;

COMMIT TRANSACTION;

SELECT COUNT(*) AS days, SUM(CAST(is_trading_day AS int)) AS trading_days FROM dw.dim_date;
GO
