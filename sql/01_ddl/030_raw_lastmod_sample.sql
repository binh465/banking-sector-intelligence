-- Raw landing table for the lastmod vs publish-time sample (raw/news/lastmod_sample/sample.csv).
-- Values as text; the comparison is done in sql/04_quality/030_lastmod_sample_analysis.sql.
-- Creates the table only if it doesn't exist, so running this file again never deletes data.
-- To change a table's structure, drop it first with 901_drop_raw_tables.sql, then reload.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'raw.raw_lastmod_sample', N'U') IS NULL
CREATE TABLE raw.raw_lastmod_sample (
    raw_id               BIGINT IDENTITY(1,1) NOT NULL,
    [stratum]            NVARCHAR(5)    NULL,
    [stratum_population] NVARCHAR(20)   NULL,
    [url]                NVARCHAR(1000) NULL,
    [lastmod]            NVARCHAR(40)   NULL,   -- sitemap value, e.g. 2025-02-01T21:05:06+07:00
    [url_timestamp]      NVARCHAR(40)   NULL,   -- parsed from the URL ID, local time
    [published_time]     NVARCHAR(40)   NULL,   -- article:published_time, local time, no offset
    [file]               NVARCHAR(1000) NULL,
    source_file          NVARCHAR(260)  NOT NULL,
    loaded_at_utc        DATETIME2(0)   NOT NULL CONSTRAINT df_raw_lastmod_sample_loaded DEFAULT SYSUTCDATETIME()
);
GO
