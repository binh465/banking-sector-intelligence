-- dw.dim_ticker: one row per version of a bank's attributes (SCD Type 2).
-- ticker_key is a surrogate key: a new version gets a new key, the ticker (durable key) stays.
-- Facts store ticker_key; analysis that runs over time partitions by ticker, not ticker_key,
-- because a rename splits one ticker into two keys.
-- valid_from / valid_to are inclusive dates. The first version starts on 1900-01-01 (the name held
-- since before the window); the current version ends on 9999-12-31, not NULL, so a lookup is a
-- plain BETWEEN.
-- Loaded by sql/03_transform/310_load_dim_ticker.sql. Creates the table only if it doesn't exist.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'dw.dim_ticker', N'U') IS NULL
CREATE TABLE dw.dim_ticker (
    ticker_key  INT IDENTITY(1,1) NOT NULL,
    ticker      NVARCHAR(10)      NOT NULL,   -- durable key, same type as stg.stg_price_daily.ticker
    full_name   NVARCHAR(200)     NOT NULL,
    exchange    NVARCHAR(10)      NOT NULL,
    valid_from  DATE              NOT NULL,
    valid_to    DATE              NOT NULL,
    is_current  BIT               NOT NULL,
    CONSTRAINT pk_dim_ticker PRIMARY KEY (ticker_key),
    CONSTRAINT uq_dim_ticker_version UNIQUE (ticker, valid_from),
    CONSTRAINT ck_dim_ticker_range CHECK (valid_from <= valid_to),
    CONSTRAINT ck_dim_ticker_current CHECK (
        (is_current = 1 AND valid_to = '9999-12-31') OR (is_current = 0 AND valid_to < '9999-12-31'))
);

-- At most one current version per ticker.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ux_dim_ticker_current' AND object_id = OBJECT_ID(N'dw.dim_ticker'))
CREATE UNIQUE INDEX ux_dim_ticker_current ON dw.dim_ticker (ticker) WHERE is_current = 1;
GO
