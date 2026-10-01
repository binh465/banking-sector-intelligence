-- dw.dim_date: one row per calendar day in the locked window, trading or not.
-- Power BI needs a continuous date column to mark it as the date table; trading days are picked
-- with is_trading_day, never by leaving rows out. session_seq numbers trading days only, so
-- "N sessions before" is a subtraction instead of date arithmetic.
-- date_key is yyyymmdd. A readable key is the usual exception to meaningless surrogate keys for a
-- date dimension: a date never changes, so there is no history to track.
-- Loaded by sql/03_transform/300_load_dim_date.sql. Creates the table only if it doesn't exist.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'dw.dim_date', N'U') IS NULL
CREATE TABLE dw.dim_date (
    date_key                 INT       NOT NULL,  -- yyyymmdd
    full_date                DATE      NOT NULL,
    [year]                   SMALLINT  NOT NULL,
    [quarter]                TINYINT   NOT NULL,
    [month]                  TINYINT   NOT NULL,
    month_start              DATE      NOT NULL,
    day_of_month             TINYINT   NOT NULL,
    iso_week                 TINYINT   NOT NULL,
    day_of_week              TINYINT   NOT NULL,  -- 1 = Monday ... 7 = Sunday, independent of SET DATEFIRST
    is_weekend               BIT       NOT NULL,
    is_trading_day           BIT       NOT NULL,  -- the date is a VNINDEX session in stg.stg_calendar
    session_seq              SMALLINT  NULL,      -- 1..n over trading days only; NULL on other days
    CONSTRAINT pk_dim_date PRIMARY KEY (date_key),
    CONSTRAINT uq_dim_date_full_date UNIQUE (full_date),
    CONSTRAINT ck_dim_date_key CHECK (date_key = [year] * 10000 + [month] * 100 + day_of_month),
    CONSTRAINT ck_dim_date_session CHECK (
        (is_trading_day = 1 AND session_seq IS NOT NULL) OR
        (is_trading_day = 0 AND session_seq IS NULL))
);

-- One row per session number, so "the session N before" is an index seek on session_seq.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ux_dim_date_session_seq' AND object_id = OBJECT_ID(N'dw.dim_date'))
CREATE UNIQUE INDEX ux_dim_date_session_seq ON dw.dim_date (session_seq) WHERE session_seq IS NOT NULL;
GO
