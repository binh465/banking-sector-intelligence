-- Staging tables for prices: typed, keyed, cut to the locked window.
--   stg_scope        the window as dates (one row)
--   stg_calendar     VNINDEX sessions inside the window = the trading calendar
--   stg_price_daily  one row per ticker per session inside the window
-- Loaded by sql/02_load/100_load_stg_price.sql. The primary keys make a duplicate row fail the insert.
-- Creates the tables only if they don't exist.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'stg.stg_scope', N'U') IS NULL
CREATE TABLE stg.stg_scope (
    start_date DATE NOT NULL,
    end_date   DATE NOT NULL,
    base_date  DATE NOT NULL,
    CONSTRAINT ck_stg_scope_order CHECK (start_date <= base_date AND base_date <= end_date)
);

IF OBJECT_ID(N'stg.stg_calendar', N'U') IS NULL
CREATE TABLE stg.stg_calendar (
    trade_date        DATE           NOT NULL,
    open_index        DECIMAL(18,4)  NOT NULL,
    high_index        DECIMAL(18,4)  NOT NULL,
    low_index         DECIMAL(18,4)  NOT NULL,
    close_index       DECIMAL(18,4)  NOT NULL,
    volume            BIGINT         NOT NULL,
    downloaded_at_utc DATETIME2(0)   NOT NULL,
    loaded_at_utc     DATETIME2(0)   NOT NULL CONSTRAINT df_stg_calendar_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_stg_calendar PRIMARY KEY (trade_date)
);

IF OBJECT_ID(N'stg.stg_price_daily', N'U') IS NULL
CREATE TABLE stg.stg_price_daily (
    ticker            NVARCHAR(10)   NOT NULL,
    trade_date        DATE           NOT NULL,
    open_price        DECIMAL(18,4)  NOT NULL,   -- thousand VND, as adjusted by VCI
    high_price        DECIMAL(18,4)  NOT NULL,
    low_price         DECIMAL(18,4)  NOT NULL,
    close_price       DECIMAL(18,4)  NOT NULL,
    volume            BIGINT         NOT NULL,
    source            NVARCHAR(20)   NOT NULL,
    vnstock_version   NVARCHAR(20)   NOT NULL,
    downloaded_at_utc DATETIME2(0)   NOT NULL,
    loaded_at_utc     DATETIME2(0)   NOT NULL CONSTRAINT df_stg_price_daily_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_stg_price_daily PRIMARY KEY (ticker, trade_date)
);
GO
