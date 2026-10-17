USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_pbi_episode_news AS
SELECT CONCAT(n.ticker, '|', n.start_seq) AS episode_key,
	n.article_key,
	n.match_tier,
	n.item_type,
	n.title,
	a.url,
	n.publish_time_local,
	n.reaction_seq,
	n.offset_from_start,
	n.position
FROM mart.v_episode_news n
LEFT JOIN dw.dim_article a ON a.article_key = n.article_key;
GO