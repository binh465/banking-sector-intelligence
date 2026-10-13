-- mart.v_episode_news: alert episodes with the single-bank news items around them.
-- Grain: one row per (episode, news item); an episode with no item keeps one row with NULL news columns.
-- News: dw.fact_news, is_sector_news = 0, reaction session from start_seq - 2 to end_seq + 2 of the
-- episode, same ticker (durable code via dim_ticker). Counted in sessions, not calendar days.
-- position: 'before' / 'during' / 'after' the episode by reaction session. An 'after' item cannot have
-- caused the episode; it is kept to measure how often the press follows the price.
-- Nearness in time is not cause: an item near an episode is a coincidence in timing.
USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_episode_news AS
WITH n AS (
	-- single-bank news items with a reaction session inside the window
	SELECT t.ticker, f.article_key, f.match_tier, 
		rd.session_seq AS reaction_seq, rd.full_date AS reaction_date
	FROM dw.fact_news f
	JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
	JOIN dw.dim_date rd ON rd.date_key = f.reaction_date_key
	WHERE f.is_sector_news = 0 AND f.reaction_date_key IS NOT NULL
)
SELECT e.ticker, e.direction, e.start_seq, e.end_seq, e.start_date, e.end_date,
		e.sessions, e.peak_z,
		n.article_key, n.match_tier, a.item_type, a.title, a.publish_time_local,
		n.reaction_date, n.reaction_seq,
		n.reaction_seq - e.start_seq AS offset_from_start,
		CASE WHEN n.article_key IS NULL THEN NULL
			WHEN n.reaction_seq < e.start_seq THEN 'before'
			WHEN n.reaction_seq <= e.end_seq THEN 'during'
			ELSE 'after' END AS position
FROM mart.v_alert_episode e
LEFT JOIN n ON e.ticker = n.ticker AND n.reaction_seq BETWEEN e.start_seq - 2 AND e.end_seq + 2
LEFT JOIN dw.dim_article a ON a.article_key = n.article_key;
GO