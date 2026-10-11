-- mart.v_excess_iqr: rolling IQR of excess_ret over the 60 sessions before each session.
-- PERCENTILE_CONT does not take a ROWS frame in T-SQL, so the 60 earlier rows of each session are
-- fetched with OUTER APPLY (OUTER keeps sessions whose earlier set is empty). TOP (1): the
-- percentile is the same on all 60 rows of the subquery.
-- PERCENTILE_CONT interpolates between values; Q1, median and Q3 need not be observed returns.
-- Flags only when the earlier set holds 60 excess returns and the current one exists:
--   out_1_5  outside Q1 - 1.5 * IQR .. Q3 + 1.5 * IQR
--   out_3    outside Q1 - 3 * IQR   .. Q3 + 3 * IQR
USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_excess_iqr AS
SELECT o.ticker, o.session_seq, o.date_key, o.full_date, o.excess_ret,
       q.n_prev, q.q1, q.q2, q.q3, v.iqr,
       CASE WHEN q.n_prev = 60 AND o.excess_ret IS NOT NULL
            THEN CASE WHEN o.excess_ret < q.q1 - 1.5 * v.iqr
                        OR o.excess_ret > q.q3 + 1.5 * v.iqr
                      THEN 1 ELSE 0 END
       END AS out_1_5,
       CASE WHEN q.n_prev = 60 AND o.excess_ret IS NOT NULL
            THEN CASE WHEN o.excess_ret < q.q1 - 3.0 * v.iqr
                        OR o.excess_ret > q.q3 + 3.0 * v.iqr
                      THEN 1 ELSE 0 END
       END AS out_3
FROM mart.v_relative_strength o
OUTER APPLY (
    SELECT TOP (1)
           COUNT(*) OVER () AS n_prev,
           PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY i.excess_ret) OVER () AS q1,
           PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY i.excess_ret) OVER () AS q2,
           PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY i.excess_ret) OVER () AS q3
    FROM mart.v_relative_strength i
    WHERE i.ticker = o.ticker
      AND i.session_seq BETWEEN o.session_seq - 60 AND o.session_seq - 1
      AND i.excess_ret IS NOT NULL
) q
OUTER APPLY (SELECT q.q3 - q.q1 AS iqr) v;
GO