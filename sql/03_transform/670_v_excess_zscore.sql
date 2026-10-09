-- mart.v_excess_zscore: z-score of excess_ret against the 60 sessions before it.
-- Window: ROWS BETWEEN 60 PRECEDING AND 1 PRECEDING, partitioned by ticker. The current session is
-- left out so a large move does not widen its own standard deviation.
-- z only when the window holds 60 real excess returns and the current one exists.
-- sd is the sample standard deviation (STDEV, n - 1).
-- With equal weights and all 10 returns present, excess_ret = 0.9 * (ret - mean of the other 9),
-- so z equals the z-score against a sector that leaves the ticker out.
USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_excess_zscore AS
WITH w AS (
	SELECT ticker, session_seq, date_key, full_date, excess_ret,
		COUNT(excess_ret) OVER (PARTITION BY ticker ORDER BY session_seq ROWS BETWEEN 60 PRECEDING AND 1 PRECEDING) AS n_prev,
		AVG(excess_ret) OVER (PARTITION BY ticker ORDER BY session_seq ROWS BETWEEN 60 PRECEDING AND 1 PRECEDING) AS mean_prev,
		STDEV(excess_ret) OVER (PARTITION BY ticker ORDER BY session_seq ROWS BETWEEN 60 PRECEDING AND 1 PRECEDING) AS sd_prev
	FROM mart.v_relative_strength
)
SELECT ticker, session_seq, date_key, full_date, excess_ret, n_prev, mean_prev, sd_prev,
	CASE WHEN n_prev = 60 AND excess_ret IS NOT NULL THEN (excess_ret - mean_prev) / NULLIF(sd_prev, 0.0) END AS z
FROM w;