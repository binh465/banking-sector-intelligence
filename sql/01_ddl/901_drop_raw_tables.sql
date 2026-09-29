-- DESTRUCTIVE: drops the raw landing tables so the DDL files can recreate them with a new structure.
-- Everything in raw can be reloaded from files in the repo / raw folder:
--   raw_price_daily, raw_calendar  <- ingest/load_prices.py        (raw/prices, raw/calendar)
--   raw_ticker_news                <- ingest/load_ticker_news.py   (raw/news/ticker)
--   raw_lastmod_sample             <- ingest/load_lastmod_sample.py (raw/news/lastmod_sample)
--   raw_article, raw_article_page  <- ingest/load_articles.py       (raw/news/sitemaps, raw/news/article_pages)
-- Step 1: look at what is there. Step 2: uncomment only the tables you mean to drop.
USE BankingSectorIntelligence;

SELECT t.name, t.create_date, SUM(p.rows) AS row_count
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE t.schema_id = SCHEMA_ID(N'raw')
GROUP BY t.name, t.create_date
ORDER BY t.name;
GO

-- DROP TABLE IF EXISTS raw.raw_price_daily;
-- DROP TABLE IF EXISTS raw.raw_calendar;
-- DROP TABLE IF EXISTS raw.raw_ticker_news;
-- DROP TABLE IF EXISTS raw.raw_lastmod_sample;
-- DROP TABLE IF EXISTS raw.raw_article;
-- DROP TABLE IF EXISTS raw.raw_article_page;
-- GO
