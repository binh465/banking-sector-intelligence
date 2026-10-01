-- dw.fact_news: factless fact table.
-- Grain: one row per news item per bank (of the 10) the item is tied to.
-- Filled in Phase 5 (matching rules); Phase 3 only creates the structure.
-- dim_date plays two roles:
--   publish_date_key   the date the item was published (Vietnam time)
--   reaction_date_key  the first session that can react to it: the publish date if published
--                      before 15:00 on a trading day, else the next trading day. NULL when that
--                      session falls after the window (no row in dim_date for it).
-- ticker_key is the dim_ticker version valid on the publish date (the name in use when the item
-- was written). Analysis over time joins on the durable ticker.
-- The match attributes describe the item-bank pair, so they live here, not in a dimension.
-- Creates the table only if it doesn't exist.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'dw.fact_news', N'U') IS NULL
CREATE TABLE dw.fact_news (
    article_key        INT       NOT NULL,
    ticker_key         INT       NOT NULL,
    publish_date_key   INT       NOT NULL,
    reaction_date_key  INT       NULL,
    match_tier         TINYINT   NOT NULL,  -- 0 = disclosure from the bank's own list, 1 = ticker in title,
                                            -- 2 = full bank name, 3 = weak alias + banking context word
    banks_mentioned    SMALLINT  NOT NULL,  -- banks named in the item, counting banks outside the 10
    is_sector_news     AS CAST(CASE WHEN banks_mentioned >= 3 THEN 1 ELSE 0 END AS bit) PERSISTED,
    CONSTRAINT pk_fact_news PRIMARY KEY (article_key, ticker_key),
    CONSTRAINT fk_fact_news_article  FOREIGN KEY (article_key)       REFERENCES dw.dim_article (article_key),
    CONSTRAINT fk_fact_news_ticker   FOREIGN KEY (ticker_key)        REFERENCES dw.dim_ticker (ticker_key),
    CONSTRAINT fk_fact_news_publish  FOREIGN KEY (publish_date_key)  REFERENCES dw.dim_date (date_key),
    CONSTRAINT fk_fact_news_reaction FOREIGN KEY (reaction_date_key) REFERENCES dw.dim_date (date_key),
    CONSTRAINT ck_fact_news_tier     CHECK (match_tier BETWEEN 0 AND 3),
    CONSTRAINT ck_fact_news_banks    CHECK (banks_mentioned >= 1),
    CONSTRAINT ck_fact_news_order    CHECK (reaction_date_key IS NULL OR reaction_date_key >= publish_date_key)
);

-- Phase 7 looks up items by bank and reaction session.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_fact_news_ticker_reaction' AND object_id = OBJECT_ID(N'dw.fact_news'))
CREATE INDEX ix_fact_news_ticker_reaction ON dw.fact_news (ticker_key, reaction_date_key);
GO
