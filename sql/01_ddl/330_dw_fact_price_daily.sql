-- dw.fact_price_daily: periodic snapshot of prices.
-- Grain: one row per ticker per trading session.
-- ticker_key points to the dim_ticker version valid on that session, so STB's rows before and after
-- 2026-06-01 carry different keys; it is still one row per ticker per session. The grain check
-- therefore groups by the durable ticker, not by ticker_key.
-- Measures: open/high/low/close are non-additive (summing prices means nothing); volume is additive
-- across tickers and sessions.
-- Loaded by sql/03_transform/330_load_fact_price_daily.sql. Creates the table only if it doesn't exist.
-- Once this table exists, TRUNCATE on dim_ticker or dim_date fails (they are referenced by a
-- foreign key); dimensions are reloaded by the Phase 4 procedures from then on.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'dw.fact_price_daily', N'U') IS NULL
CREATE TABLE dw.fact_price_daily (
    ticker_key   INT            NOT NULL,
    date_key     INT            NOT NULL,
    open_price   DECIMAL(18,4)  NOT NULL,   -- thousand VND, adjusted by VCI
    high_price   DECIMAL(18,4)  NOT NULL,
    low_price    DECIMAL(18,4)  NOT NULL,
    close_price  DECIMAL(18,4)  NOT NULL,
    volume       BIGINT         NOT NULL,
    CONSTRAINT pk_fact_price_daily PRIMARY KEY (ticker_key, date_key),
    CONSTRAINT fk_fact_price_daily_ticker FOREIGN KEY (ticker_key) REFERENCES dw.dim_ticker (ticker_key),
    CONSTRAINT fk_fact_price_daily_date   FOREIGN KEY (date_key)   REFERENCES dw.dim_date (date_key),
    CONSTRAINT ck_fact_price_daily_prices CHECK (
        low_price > 0 AND low_price <= high_price
        AND open_price  BETWEEN low_price AND high_price
        AND close_price BETWEEN low_price AND high_price),
    CONSTRAINT ck_fact_price_daily_volume CHECK (volume >= 0)
);
GO
