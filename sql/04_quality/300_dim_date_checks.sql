USE BankingSectorIntelligence;

-- 1. One row per calendar day: row count vs the number of days in the window, first and last date.
SELECT COUNT(*)                                            AS rows_in_dim,
       DATEDIFF(day, s.start_date, s.end_date) + 1          AS days_in_window,
       COUNT(DISTINCT d.full_date)                          AS distinct_dates,
       MIN(d.full_date) AS first_date, s.start_date,
       MAX(d.full_date) AS last_date,  s.end_date
FROM dw.dim_date d CROSS JOIN stg.stg_scope s
GROUP BY s.start_date, s.end_date;

-- 2. Trading days vs the calendar, and session_seq running 1..n.
SELECT SUM(CAST(is_trading_day AS int))                     AS trading_days,
       (SELECT COUNT(*) FROM stg.stg_calendar)              AS calendar_sessions,
       MIN(session_seq)                                     AS min_seq,
       MAX(session_seq)                                     AS max_seq,
       COUNT(DISTINCT session_seq)                          AS distinct_seq
FROM dw.dim_date;

-- 3. Gaps or order breaks in session_seq: consecutive trading days must differ by exactly 1.
WITH s AS (
    SELECT full_date, session_seq,
           LAG(session_seq) OVER (ORDER BY full_date) AS prev_seq
    FROM dw.dim_date
    WHERE is_trading_day = 1
)
SELECT full_date, prev_seq, session_seq
FROM s
WHERE prev_seq IS NOT NULL AND session_seq - prev_seq <> 1;

-- 4. Calendar sessions not flagged as trading days, and trading days that are not calendar sessions.
SELECT N'in calendar, not trading in dim' AS issue, c.trade_date AS full_date
FROM stg.stg_calendar c
WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date d WHERE d.full_date = c.trade_date AND d.is_trading_day = 1)
UNION ALL
SELECT N'trading in dim, not in calendar', d.full_date
FROM dw.dim_date d
WHERE d.is_trading_day = 1
  AND NOT EXISTS (SELECT 1 FROM stg.stg_calendar c WHERE c.trade_date = d.full_date);

-- 5. Trading days on a weekend (day_of_week 6 or 7).
SELECT full_date, day_of_week, DATENAME(weekday, full_date) AS day_name
FROM dw.dim_date
WHERE is_trading_day = 1 AND is_weekend = 1;

-- 6. Weekdays without a session: the market holidays. Read through the list.
SELECT full_date, DATENAME(weekday, full_date) AS day_name
FROM dw.dim_date
WHERE is_trading_day = 0 AND is_weekend = 0
ORDER BY full_date;

-- 7. day_of_week against DATENAME (DATENAME follows the session language; compare by eye).
SELECT day_of_week, MIN(DATENAME(weekday, full_date)) AS name_a, MAX(DATENAME(weekday, full_date)) AS name_b,
       COUNT(*) AS days
FROM dw.dim_date
GROUP BY day_of_week
ORDER BY day_of_week;
