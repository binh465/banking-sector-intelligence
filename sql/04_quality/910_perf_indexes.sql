-- Phase 9 candidate indexes (decisions.md 2026-10-15). Every apply, revert and drop is commented out.
-- To run one: select the lines of that section that start with "-- " (not the "----" note), press
-- Ctrl+K, Ctrl+U to uncomment them, keep them selected and press F5. Notes start with "----" so they
-- stay comments after one uncomment.
-- Each index is tried alone; neither stays unless the measurements meet the rule in decisions.md.
-- Run the query at the end of the file after every change and before measuring.
USE BankingSectorIntelligence;
GO

---------------------------------------------------------------------------- I1 apply
---- For v_episode_news and the news base rate. ix_fact_news_ticker_reaction is defined in
---- 01_ddl/340 on (ticker_key, reaction_date_key); I1 is the same index with is_sector_news included.
---- DROP_EXISTING rebuilds it in place and fails if the index does not exist.
-- CREATE NONCLUSTERED INDEX ix_fact_news_ticker_reaction
--     ON dw.fact_news (ticker_key, reaction_date_key) INCLUDE (is_sector_news)
--     WITH (DROP_EXISTING = ON);
-- GO

---------------------------------------------------------------------------- I1 revert
---- Back to the 01_ddl/340 definition.
-- CREATE NONCLUSTERED INDEX ix_fact_news_ticker_reaction
--     ON dw.fact_news (ticker_key, reaction_date_key)
--     WITH (DROP_EXISTING = ON);
-- GO

---------------------------------------------------------------------------- I2 create
---- The Missing Index suggestion SSMS showed on the 680 plan.
-- IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_fact_price_daily_date'
--                                       AND object_id = OBJECT_ID(N'dw.fact_price_daily'))
--     THROW 50910, N'ix_fact_price_daily_date already exists', 1;
-- CREATE NONCLUSTERED INDEX ix_fact_price_daily_date ON dw.fact_price_daily (date_key);
-- GO

---------------------------------------------------------------------------- I2 drop
-- DROP INDEX ix_fact_price_daily_date ON dw.fact_price_daily;
-- GO

---------------------------------------------------------------------------- nonclustered indexes now
---- Key and included columns of every nonclustered index on the two fact tables.
---- Catalog views are per database: in any other database this returns no rows instead of failing.
IF DB_NAME() <> N'BankingSectorIntelligence'
    THROW 50911, N'Current database is not BankingSectorIntelligence', 1;
SELECT OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) AS table_name,
       i.name AS index_name,
       c.name AS column_name,
       ic.key_ordinal,
       ic.is_included_column
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id IN (OBJECT_ID(N'dw.fact_news'), OBJECT_ID(N'dw.fact_price_daily'))
  AND i.type = 2
ORDER BY table_name, index_name, ic.is_included_column, ic.key_ordinal;
GO
