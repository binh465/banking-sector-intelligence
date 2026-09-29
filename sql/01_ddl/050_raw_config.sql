-- Raw snapshot of config/scope.yaml and config/tickers.yaml, loaded by ingest/load_config.py,
-- so SQL reads the window and the ticker list from the same files as Python. Values as text.
-- Creates the tables only if they don't exist; drop with 901_drop_raw_tables.sql.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'raw.raw_scope', N'U') IS NULL
CREATE TABLE raw.raw_scope (
    [start_date]   NVARCHAR(20)  NULL,
    [end_date]     NVARCHAR(20)  NULL,
    [base_date]    NVARCHAR(20)  NULL,
    [locked_on]    NVARCHAR(20)  NULL,
    [price_source] NVARCHAR(200) NULL,
    [news_source]  NVARCHAR(200) NULL,
    source_file    NVARCHAR(260) NOT NULL,
    loaded_at_utc  DATETIME2(0)  NOT NULL CONSTRAINT df_raw_scope_loaded DEFAULT SYSUTCDATETIME()
);

IF OBJECT_ID(N'raw.raw_ticker_config', N'U') IS NULL
CREATE TABLE raw.raw_ticker_config (
    [ticker]      NVARCHAR(20)  NULL,
    [full_name]   NVARCHAR(400) NULL,   -- current name
    [exchange]    NVARCHAR(20)  NULL,
    source_file   NVARCHAR(260) NOT NULL,
    loaded_at_utc DATETIME2(0)  NOT NULL CONSTRAINT df_raw_ticker_config_loaded DEFAULT SYSUTCDATETIME()
);

IF OBJECT_ID(N'raw.raw_ticker_name_history', N'U') IS NULL
CREATE TABLE raw.raw_ticker_name_history (
    [ticker]             NVARCHAR(20)   NULL,
    [full_name]          NVARCHAR(400)  NULL,
    [valid_from]         NVARCHAR(20)   NULL,   -- empty = since before the window
    [valid_to]           NVARCHAR(20)   NULL,   -- empty = still current
    [name_change_source] NVARCHAR(1000) NULL,
    source_file          NVARCHAR(260)  NOT NULL,
    loaded_at_utc        DATETIME2(0)   NOT NULL CONSTRAINT df_raw_ticker_name_history_loaded DEFAULT SYSUTCDATETIME()
);
GO
