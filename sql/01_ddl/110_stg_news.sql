-- Staging tables for news: typed, keyed, cut to the locked window.
--   stg_article      one row per sitemap URL, with the publish time used from Phase 5 on
--   stg_ticker_news  one row per ticker per item in CafeF's per-ticker list (articles and disclosures)
-- Loaded by sql/02_load/110_load_stg_news.sql. Decisions: docs/decisions.md, 2026-09-30.
-- Creates the tables only if they don't exist.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'stg.stg_article', N'U') IS NULL
CREATE TABLE stg.stg_article (
    url                   VARCHAR(400)    NOT NULL,  -- ASCII only, max 254 in raw
    article_id            VARCHAR(20)     NOT NULL,  -- digits between the last '-' and '.chn'; not unique
    id_url_count          SMALLINT        NOT NULL,  -- sitemap URLs sharing this article_id (whole sitemap)
    sitemap_title         NVARCHAR(1000)  NOT NULL,  -- from the kept sitemap row
    og_title              NVARCHAR(1000)  NULL,      -- from the article page, if fetched
    lastmod_local         DATETIME2(0)    NOT NULL,  -- sitemap lastmod, Vietnam time (+07:00 dropped)
    page_published_local  DATETIME2(0)    NULL,      -- article:published_time, Vietnam time
    publish_time_local    DATETIME2(0)    NOT NULL,  -- page time if present, else lastmod
    time_source           VARCHAR(10)     NOT NULL,  -- 'page' or 'lastmod'
    page_fetched          BIT             NOT NULL,
    sitemap_rows          TINYINT         NOT NULL,  -- rows for this URL in raw.raw_article (1 to 3)
    source_file           NVARCHAR(260)   NOT NULL,  -- sitemap file of the kept row
    page_fetched_at_utc   DATETIME2(0)    NULL,
    loaded_at_utc         DATETIME2(0)    NOT NULL CONSTRAINT df_stg_article_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_stg_article PRIMARY KEY (url),
    CONSTRAINT ck_stg_article_time_source CHECK (
        (time_source = 'page'    AND page_published_local IS NOT NULL AND publish_time_local = page_published_local) OR
        (time_source = 'lastmod' AND page_published_local IS NULL     AND publish_time_local = lastmod_local)),
    CONSTRAINT ck_stg_article_page CHECK (page_fetched = 1 OR (page_published_local IS NULL AND og_title IS NULL))
);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_stg_article_article_id' AND object_id = OBJECT_ID(N'stg.stg_article'))
CREATE INDEX ix_stg_article_article_id ON stg.stg_article (article_id);

IF OBJECT_ID(N'stg.stg_ticker_news', N'U') IS NULL
CREATE TABLE stg.stg_ticker_news (
    ticker           NVARCHAR(10)    NOT NULL,
    url              VARCHAR(400)    NOT NULL,  -- https://cafef.vn + path, query string removed
    item_kind        VARCHAR(10)     NOT NULL,  -- 'article' or 'disclosure' (path under /du-lieu/)
    article_id       VARCHAR(20)     NULL,      -- articles only, same rule as stg_article
    list_time_local  DATETIME2(0)    NOT NULL,  -- time shown in the list, Vietnam time
    is_date_only     BIT             NOT NULL,  -- disclosure listed at 00:00 = time unknown
    title            NVARCHAR(1000)  NOT NULL,
    page_no          SMALLINT        NOT NULL,
    item_position    SMALLINT        NOT NULL,
    fetched_at_utc   DATETIME2(0)    NOT NULL,
    source_file      NVARCHAR(260)   NOT NULL,
    loaded_at_utc    DATETIME2(0)    NOT NULL CONSTRAINT df_stg_ticker_news_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_stg_ticker_news PRIMARY KEY (ticker, url),
    CONSTRAINT ck_stg_ticker_news_kind CHECK (item_kind IN ('article', 'disclosure')),
    CONSTRAINT ck_stg_ticker_news_date_only CHECK (is_date_only = 0 OR item_kind = 'disclosure')
);
GO
