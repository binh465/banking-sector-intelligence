-- Raw snapshot of docs/precision_sample.csv (the hand-labelled precision sample), loaded by
-- ingest/load_precision_labels.py. One row per sampled item-bank pair, every value as text.
-- Label columns are empty until labelled.
-- Creates the table only if it doesn't exist; drop with 901_drop_raw_tables.sql.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'raw.raw_precision_label', N'U') IS NULL
CREATE TABLE raw.raw_precision_label (
    [label_order]         NVARCHAR(20)    NULL,
    [stratum]             NVARCHAR(20)    NULL,
    [url]                 NVARCHAR(400)   NULL,
    [ticker]              NVARCHAR(20)    NULL,
    [matched_term]        NVARCHAR(200)   NULL,
    [title]               NVARCHAR(1000)  NULL,
    [publish_time_local]  NVARCHAR(40)    NULL,
    [stratum_pairs]       NVARCHAR(20)    NULL,
    [is_correct]          NVARCHAR(10)    NULL,
    [is_main_subject]     NVARCHAR(10)    NULL,
    [note]                NVARCHAR(1000)  NULL,
    source_file           NVARCHAR(260)   NOT NULL,
    loaded_at_utc         DATETIME2(0)    NOT NULL CONSTRAINT df_raw_precision_label_loaded DEFAULT SYSUTCDATETIME()
);
GO