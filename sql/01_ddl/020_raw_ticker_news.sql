-- Raw landing table for CafeF's per-ticker news list (raw/news/ticker/*.html).
-- One row per list item, values as text exactly as parsed from the HTML; typing happens in stg.
-- DROP + CREATE is safe: the table is fully reloadable from the saved HTML files.
USE BankingSectorIntelligence;
GO

DROP TABLE IF EXISTS raw.raw_ticker_news;
CREATE TABLE raw.raw_ticker_news (
    raw_id          BIGINT IDENTITY(1,1) NOT NULL,
    [ticker]        NVARCHAR(20)   NULL,   -- ticker whose list the item came from (file name)
    [page]          NVARCHAR(10)   NULL,
    [item_position] NVARCHAR(10)   NULL,   -- 1..30 within the page
    [time_text]     NVARCHAR(40)   NULL,   -- as shown, dd/mm/yyyy HH:MM
    [title]         NVARCHAR(1000) NULL,
    [href]          NVARCHAR(1000) NULL,   -- as in the HTML, including utm parameters
    [fetched_at_utc] NVARCHAR(40)  NULL,   -- from raw/news/ticker/_fetch_log.csv
    source_file     NVARCHAR(260)  NOT NULL,
    loaded_at_utc   DATETIME2(0)   NOT NULL CONSTRAINT df_raw_ticker_news_loaded DEFAULT SYSUTCDATETIME()
);
GO
