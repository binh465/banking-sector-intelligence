-- mart.v_rolling_corr: 60-session correlation between ticker return and sector return.
-- Window: the current session and the 59 before it (ROWS, partitioned by ticker).
-- T-SQL has no CORR aggregate: built from six running sums. Returned only when the window holds
-- 60 sessions with both returns; that also makes all six sums run over the same 60 pairs.
-- Uses returns, not index levels: two trending series correlate even when unrelated.
USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_rolling_corr AS
WITH w AS (
	SELECT ticker, session_seq, date_key, full_date, ret, sector_ret,
		COUNT(CASE WHEN ret IS NOT NULL AND sector_ret IS NOT NULL THEN 1 END)  
			OVER (PARTITION BY ticker ORDER BY session_seq ROWS BETWEEN 59 PRECEDING AND CURRENT ROW)							AS n,
		SUM(ret) OVER (PARTITION BY ticker ORDER BY session_seq ROWS BETWEEN 59 PRECEDING AND CURRENT ROW)						AS sx,
		SUM(sector_ret) OVER (PARTITION BY ticker ORDER BY session_seq ROWS BETWEEN 59 PRECEDING AND CURRENT ROW)				AS sy,
		SUM(ret * sector_ret) OVER (PARTITION BY ticker ORDER BY session_seq ROWS BETWEEN 59 PRECEDING AND CURRENT ROW)			AS sxy,
		SUM(ret * ret) OVER (PARTITION BY ticker ORDER BY session_seq ROWS BETWEEN 59 PRECEDING AND CURRENT ROW)				AS sxx,
		SUM(sector_ret * sector_ret) OVER (PARTITION BY ticker ORDER BY session_seq ROWS BETWEEN 59 PRECEDING AND CURRENT ROW)	AS syy
	FROM mart.v_relative_strength
)
SELECT ticker, session_seq, date_key, full_date, n,
	CASE WHEN n = 60 THEN (n * sxy - sx * sy) / NULLIF(SQRT((n * sxx - sx * sx) * (n * syy - sy * sy)), 0.0) END AS corr_60
FROM w;
GO