-- mart.v_return_daily: simple return per ticker per session, close over the previous session's close.
-- The previous row must be the previous session (session_seq - 1); otherwise the return is NULL, so a
-- missing session never turns into a two-session return. The first session of the window has no return.
USE BankingSectorIntelligence
GO

CREATE OR ALTER VIEW mart.v_return_daily
AS
WITH p AS (
	SELECT ticker, date_key, full_date, session_seq, close_price,
		LAG(close_price) OVER (PARTITION BY ticker ORDER BY session_seq) AS prev_close,
		LAG(session_seq) OVER (PARTITION BY ticker ORDER BY session_seq) AS prev_session_seq
	FROM mart.v_price_session
)
SELECT ticker, date_key, full_date, session_seq, close_price, prev_close,
	CASE WHEN prev_session_seq = session_seq - 1 
		THEN CAST(close_price AS float) / CAST(prev_close AS float) - 1
	END AS ret
FROM p;
GO