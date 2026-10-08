-- mart.v_sector_return: equal-weighted sector return per session = average of the tickers' returns.
-- sector_ret is set only when every ticker has a return in that session, so the average always covers
-- the same set of banks; tickers_with_return shows when that is not the case.
USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_sector_return
AS
WITH n AS (
	SELECT COUNT(DISTINCT ticker) AS tickers
	FROM mart.v_price_session
)
SELECT r.session_seq, r.date_key, r.full_date, COUNT(r.ret) AS tickers_with_return,
	CASE WHEN COUNT(r.ret) = MAX(n.tickers) THEN AVG(r.ret) END AS sector_ret
FROM mart.v_return_daily r
CROSS JOIN n 
GROUP BY r.session_seq, r.date_key, r.full_date;
GO