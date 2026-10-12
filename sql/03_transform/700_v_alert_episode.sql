-- mart.v_alert_episode: one row per alert episode.
-- Alert session: |z| >= 3 (decisions.md 2026-10-09). Episode: alert sessions of one ticker and one
-- direction (sign of z) with consecutive session_seq, no gap allowed (decisions.md 2026-10-12).
-- Gaps and islands: session_seq - ROW_NUMBER() over (ticker, direction) is constant inside a run.
-- Key: (ticker, start_seq). sum_excess_ret is a plain sum of daily excess returns, not compounded.
USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_alert_episode AS
WITH a AS (
    -- alert sessions only; the threshold is the one fixed in decisions.md (2026-10-09)
    SELECT ticker, session_seq, date_key, full_date, z, excess_ret,
           CAST(SIGN(z) AS smallint) AS direction
    FROM mart.v_excess_zscore
	WHERE ABS(z) >= 3
),
g AS (
    SELECT ticker, session_seq, date_key, full_date, z, excess_ret, direction,
           session_seq - ROW_NUMBER() OVER (PARTITION BY ticker, direction ORDER BY session_seq) AS grp
    FROM a
)
SELECT ticker,
       direction,
       MIN(session_seq) AS start_seq,
       MAX(session_seq) AS end_seq,
       MIN(date_key) AS start_date_key,
       MAX(date_key) AS end_date_key,
       MIN(full_date) AS start_date,
       MAX(full_date) AS end_date,
       COUNT(*) AS sessions,
       direction * MAX(ABS(z)) AS peak_z,
       SUM(excess_ret) AS sum_excess_ret
FROM g
GROUP BY ticker, direction, grp;
GO