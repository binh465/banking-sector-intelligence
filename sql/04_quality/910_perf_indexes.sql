-- Phase 9 candidate indexes (decisions.md 2026-10-15). Every create and drop is commented out:
-- select one section, uncomment it in the selection or copy it, and run only that, as 900 says.
-- Each is tried alone; neither stays unless the measurements meet the rule in decisions.md.
USE BankingSectorIntelligence;
GO

---------------------------------------------------------------------------- I1 create
-- For v_episode_news and the news base rate: news by ticker and reaction session.
-- IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_fact_news_ticker_reaction'
--                                           AND object_id = OBJECT_ID(N'dw.fact_news'))
--     CREATE NONCLUSTERED INDEX ix_fact_news_ticker_reaction
--         ON dw.fact_news (ticker_key, reaction_date_key) INCLUDE (is_sector_news);
-- GO

---------------------------------------------------------------------------- I1 drop
-- DROP INDEX IF EXISTS ix_fact_news_ticker_reaction ON dw.fact_news;
-- GO

---------------------------------------------------------------------------- I2 create
-- The Missing Index suggestion SSMS showed on the 680 plan.
-- IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_fact_price_daily_date'
--                                           AND object_id = OBJECT_ID(N'dw.fact_price_daily'))
--     CREATE NONCLUSTERED INDEX ix_fact_price_daily_date ON dw.fact_price_daily (date_key);
-- GO

---------------------------------------------------------------------------- I2 drop
-- DROP INDEX IF EXISTS ix_fact_price_daily_date ON dw.fact_price_daily;
-- GO

---------------------------------------------------------------------------- which candidates exist now
SELECT OBJECT_SCHEMA_NAME(object_id) + N'.' + OBJECT_NAME(object_id) AS table_name, name AS index_name
FROM sys.indexes
WHERE name IN (N'ix_fact_news_ticker_reaction', N'ix_fact_price_daily_date');
GO
