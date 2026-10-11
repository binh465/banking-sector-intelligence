-- mart.v_excess_iqr: rolling IQR of excess_ret over the 60 sessions before each session.
-- PERCENTILE_CONT does not take a ROWS frame in T-SQL. Each session is joined to its 60 earlier
-- sessions (same ticker, session_seq s-60 .. s-1), and the percentiles are taken per session over
-- those rows. A join, not OUTER APPLY with TOP (1): the APPLY form forced the whole view chain to be
-- recomputed once per outer row (123 s on 4,970 rows); the join lets each side be computed once.
-- PERCENTILE_CONT interpolates between values; Q1, median and Q3 need not be observed returns.
-- Flags only when the earlier set holds 60 excess returns and the current one exists:
--   out_1_5  outside Q1 - 1.5 * IQR .. Q3 + 1.5 * IQR
--   out_3    outside Q1 - 3 * IQR   .. Q3 + 3 * IQR
USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_excess_iqr AS
WITH x AS (
    SELECT ticker, session_seq, date_key, full_date, excess_ret
    FROM mart.v_relative_strength
),
win AS (
    -- one row per (session, earlier session inside its 60-session window)
    SELECT o.ticker, o.session_seq, i.excess_ret
    FROM x o
    JOIN x i ON i.ticker = o.ticker
            AND i.session_seq BETWEEN o.session_seq - 60 AND o.session_seq - 1
    WHERE i.excess_ret IS NOT NULL
),
q AS (
    SELECT DISTINCT ticker, session_seq,
           COUNT(*) OVER (PARTITION BY ticker, session_seq) AS n_prev,
           PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY excess_ret) OVER (PARTITION BY ticker, session_seq) AS q1,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY excess_ret) OVER (PARTITION BY ticker, session_seq) AS q2,
           PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY excess_ret) OVER (PARTITION BY ticker, session_seq) AS q3
    FROM win
)
SELECT x.ticker, x.session_seq, x.date_key, x.full_date, x.excess_ret,
       q.n_prev, q.q1, q.q2, q.q3, v.iqr,
       CASE WHEN q.n_prev = 60 AND x.excess_ret IS NOT NULL
            THEN CASE WHEN x.excess_ret < q.q1 - 1.5 * v.iqr
                        OR x.excess_ret > q.q3 + 1.5 * v.iqr
                      THEN 1 ELSE 0 END
       END AS out_1_5,
       CASE WHEN q.n_prev = 60 AND x.excess_ret IS NOT NULL
            THEN CASE WHEN x.excess_ret < q.q1 - 3.0 * v.iqr
                        OR x.excess_ret > q.q3 + 3.0 * v.iqr
                      THEN 1 ELSE 0 END
       END AS out_3
FROM x
LEFT JOIN q ON q.ticker = x.ticker AND q.session_seq = x.session_seq
OUTER APPLY (SELECT q.q3 - q.q1 AS iqr) v;
GO