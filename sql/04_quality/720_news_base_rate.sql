-- News base rate: single-bank items in the 5-session window around ordinary sessions vs alert sessions.
WITH news_per_session AS (
	SELECT t.ticker, rd.session_seq, COUNT(*) AS items
	FROM dw.fact_news f
	JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
	JOIN dw.dim_date rd ON rd.date_key = f.reaction_date_key
	WHERE f.is_sector_news = 0
	GROUP BY t.ticker, rd.session_seq
),
s AS (
	SELECT z.ticker, z.session_seq, z.z, ISNULL(n.items, 0) AS items,
		SUM(ISNULL(n.items, 0)) OVER (PARTITION BY z.ticker ORDER BY z.session_seq
			ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING) AS items_5,
		COUNT(*) OVER (PARTITION BY z.ticker ORDER BY z.session_seq
			ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING) AS session_in_window
	FROM mart.v_excess_zscore z
	LEFT JOIN news_per_session n ON z.ticker = n.ticker AND n.session_seq = z.session_seq
)
SELECT CASE WHEN ABS(z) >= 3 THEN 'alert' ELSE 'ordinary' END AS session_group,
	COUNT(*) AS sessions,
	AVG(CAST(CASE WHEN items_5 > 0 THEN 1.0 ELSE 0 END AS DECIMAL(5, 4))) AS share_window_with_news,
	AVG(CAST(items_5 AS DECIMAL(12,3))) AS avg_items_window,
	AVG(CAST(items AS DECIMAL(12,3))) AS avg_items_session
FROM s
WHERE z IS NOT NULL AND session_in_window = 5
GROUP BY CASE WHEN ABS(z) >= 3 THEN 'alert' ELSE 'ordinary' END;