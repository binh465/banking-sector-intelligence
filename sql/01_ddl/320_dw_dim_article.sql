-- dw.dim_article: one row per news item. Two kinds (decisions.md, 2026-09-27):
--   article     CafeF articles from the sitemap (stg.stg_article)
--   disclosure  company disclosures from the per-ticker lists (stg.stg_ticker_news), one row per URL
-- Attributes are overwritten on reload (Type 1): a retitled article keeps one title here.
-- The dates an item is tied to (publish date, reaction session) live in fact_news as keys to dim_date.
-- Loaded by sql/03_transform/320_load_dim_article.sql. Creates the table only if it doesn't exist.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'dw.dim_article', N'U') IS NULL
CREATE TABLE dw.dim_article (
    article_key         INT IDENTITY(1,1) NOT NULL,
    url                 VARCHAR(400)      NOT NULL,   -- natural key
    item_type           VARCHAR(10)       NOT NULL,   -- 'article' or 'disclosure'
    article_id          VARCHAR(20)       NULL,       -- articles only; not unique
    id_url_count        SMALLINT          NULL,       -- articles only
    title               NVARCHAR(1000)    NOT NULL,   -- sitemap title (article) or list title (disclosure)
    og_title            NVARCHAR(1000)    NULL,       -- page title, articles with a fetched page
    publish_time_local  DATETIME2(0)      NOT NULL,   -- Vietnam time
    time_source         VARCHAR(10)       NOT NULL,   -- 'page', 'lastmod' (article) or 'list' (disclosure)
    has_time            BIT               NOT NULL,   -- 0 = date only (disclosure listed at 00:00)
    page_fetched        BIT               NOT NULL,
    CONSTRAINT pk_dim_article PRIMARY KEY (article_key),
    CONSTRAINT uq_dim_article_url UNIQUE (url),
    CONSTRAINT ck_dim_article_type CHECK (
        (item_type = 'article'    AND time_source IN ('page', 'lastmod') AND has_time = 1 AND article_id IS NOT NULL) OR
        (item_type = 'disclosure' AND time_source = 'list' AND article_id IS NULL AND page_fetched = 0))
);
GO
