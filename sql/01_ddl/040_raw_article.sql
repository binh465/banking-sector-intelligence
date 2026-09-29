-- Raw landing tables for CafeF articles.
--   raw_article       one row per sitemap entry (raw/news/sitemaps/*.xml). A URL that sits in two
--                     bucket files appears twice here; staging keeps one row per URL.
--   raw_article_page  one row per fetched article page (raw/news/article_pages/*.gz), with the
--                     publish time read from the page.
-- Values as text. Creates the tables only if they don't exist; drop with 901_drop_raw_tables.sql.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'raw.raw_article', N'U') IS NULL
CREATE TABLE raw.raw_article (
    raw_id          BIGINT IDENTITY(1,1) NOT NULL,
    [url]           NVARCHAR(1000) NULL,
    [lastmod]       NVARCHAR(40)   NULL,   -- as in the sitemap, e.g. 2026-09-25T23:57:48+07:00
    [title]         NVARCHAR(1000) NULL,   -- image:title with the XML escaping and CDATA wrapper removed
    source_file     NVARCHAR(260)  NOT NULL,
    loaded_at_utc   DATETIME2(0)   NOT NULL CONSTRAINT df_raw_article_loaded DEFAULT SYSUTCDATETIME()
);

IF OBJECT_ID(N'raw.raw_article_page', N'U') IS NULL
CREATE TABLE raw.raw_article_page (
    raw_id           BIGINT IDENTITY(1,1) NOT NULL,
    [url]            NVARCHAR(1000) NULL,
    [published_time] NVARCHAR(40)   NULL,   -- meta article:published_time, local time, no offset
    [og_title]       NVARCHAR(1000) NULL,   -- meta og:title, to compare with the sitemap title
    [fetched_at_utc] NVARCHAR(40)   NULL,   -- from raw/news/article_pages/_fetch_log.csv
    source_file      NVARCHAR(260)  NOT NULL,
    loaded_at_utc    DATETIME2(0)   NOT NULL CONSTRAINT df_raw_article_page_loaded DEFAULT SYSUTCDATETIME()
);
GO
