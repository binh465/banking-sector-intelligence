USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_pbi_episode AS
WITH counted AS (
	SELECT ticker, start_seq, 
		SUM(CASE WHEN position = 'before' THEN 1 ELSE 0 END) AS news_before,
		SUM(CASE WHEN position = 'during' THEN 1 ELSE 0 END) AS news_during,
		SUM(CASE WHEN position = 'after' THEN 1 ELSE 0 END) AS news_after
	FROM mart.v_episode_news
	GROUP BY ticker, start_seq
)
SELECT CONCAT(e.ticker, '|', e.start_seq) AS episode_key, 
	e.ticker, e.direction, e.start_seq, e.end_seq, e.start_date_key, e.end_date_key,e.start_date, e.end_date, e.sessions, e.peak_z,
	e.sum_excess_ret, 
	ISNULL(c.news_before, 0) AS news_before,
    ISNULL(c.news_during, 0) AS news_during,
    ISNULL(c.news_after, 0)  AS news_after
FROM mart.v_alert_episode e
LEFT JOIN counted c ON e.ticker = c.ticker AND e.start_seq = c.start_seq
GO