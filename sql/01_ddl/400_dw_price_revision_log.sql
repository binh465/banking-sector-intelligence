-- dw.price_revision_log: one row per session whose staged prices differ from the fact when a load
-- runs. Written by dw.sp_load_fact_price_daily before it restates the ticker (decisions.md, 2026-10-01).
-- Creates the table only if it doesn't exist.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'dw.price_revision_log', N'U') IS NULL
CREATE TABLE dw.price_revision_log (
    revision_id      BIGINT IDENTITY(1,1) NOT NULL,
    run_at_utc       DATETIME2(0)   NOT NULL,
    ticker           NVARCHAR(10)   NOT NULL,
    trade_date       DATE           NOT NULL,
    old_open         DECIMAL(18,4)  NOT NULL,
    old_high         DECIMAL(18,4)  NOT NULL,
    old_low          DECIMAL(18,4)  NOT NULL,
    old_close        DECIMAL(18,4)  NOT NULL,
    old_volume       BIGINT         NOT NULL,
    new_open         DECIMAL(18,4)  NOT NULL,
    new_high         DECIMAL(18,4)  NOT NULL,
    new_low          DECIMAL(18,4)  NOT NULL,
    new_close        DECIMAL(18,4)  NOT NULL,
    new_volume       BIGINT         NOT NULL,
    CONSTRAINT pk_price_revision_log PRIMARY KEY (revision_id)
);
GO
