-- Raw landing tables for the price snapshots. Every source value is text,
-- exactly as read from the parquet files; typing happens in stg.
-- DROP + CREATE is safe here: raw is fully reloadable from the committed parquet files.
USE BankingSectorIntelligence;
GO

DROP TABLE IF EXISTS raw.raw_price_daily;
CREATE TABLE raw.raw_price_daily (
    raw_id              BIGINT IDENTITY(1,1) NOT NULL,
    [symbol]            NVARCHAR(20)  NULL,
    [time]              NVARCHAR(40)  NULL,
    [open]              NVARCHAR(40)  NULL,
    [high]              NVARCHAR(40)  NULL,
    [low]               NVARCHAR(40)  NULL,
    [close]             NVARCHAR(40)  NULL,
    [volume]            NVARCHAR(40)  NULL,
    [source]            NVARCHAR(20)  NULL,
    [vnstock_version]   NVARCHAR(20)  NULL,
    [downloaded_at_utc] NVARCHAR(40)  NULL,
    source_file         NVARCHAR(260) NOT NULL,
    loaded_at_utc       DATETIME2(0)  NOT NULL CONSTRAINT df_raw_price_daily_loaded DEFAULT SYSUTCDATETIME()
);

DROP TABLE IF EXISTS raw.raw_calendar;
CREATE TABLE raw.raw_calendar (
    -- same shape as raw_price_daily; holds the VNINDEX bars used as the trading calendar
    raw_id              BIGINT IDENTITY(1,1) NOT NULL,
    [symbol]            NVARCHAR(20)  NULL,
    [time]              NVARCHAR(40)  NULL,
    [open]              NVARCHAR(40)  NULL,
    [high]              NVARCHAR(40)  NULL,
    [low]               NVARCHAR(40)  NULL,
    [close]             NVARCHAR(40)  NULL,
    [volume]            NVARCHAR(40)  NULL,
    [source]            NVARCHAR(20)  NULL,
    [vnstock_version]   NVARCHAR(20)  NULL,
    [downloaded_at_utc] NVARCHAR(40)  NULL,
    source_file         NVARCHAR(260) NOT NULL,
    loaded_at_utc       DATETIME2(0)  NOT NULL CONSTRAINT df_raw_calendar_loaded DEFAULT SYSUTCDATETIME()
);
GO