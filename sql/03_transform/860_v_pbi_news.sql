USE BankingSectorIntelligence;
GO
CREATE OR ALTER VIEW mart.v_pbi_news AS
SELECT f.article_key,
		t.ticker,
		f.publish_date_key,
		f.reaction_date_key,
		f.match_tier,
		f.is_sector_news,
		a.item_type,
		a.title,
		a.url,
		a.publish_time_local
FROM dw.fact_news f
JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
JOIN dw.dim_article a ON a.article_key = f.article_key;
GO