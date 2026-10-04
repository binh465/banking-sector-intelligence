-- Raw snapshot of config/aliases.yaml, loaded by ingest/load_aliases.py. One row per term.
--   kind = 'context'   a context word (bank_id, ticker, in_scope empty)
--   kind = 'exclusion' a phrase cut out of titles before matching (bank_id, ticker, in_scope empty)
--   kind = 'strong' / 'weak'  a bank alias; bank_id = ticker for the 10 banks, else the id in the yaml
-- Values as text. Creates the table only if it doesn't exist; drop with 901_drop_raw_tables.sql.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'raw.raw_alias', N'U') IS NULL
CREATE TABLE raw.raw_alias (
    [kind]            NVARCHAR(20)   NULL,
    [bank_id]         NVARCHAR(20)   NULL,
    [ticker]          NVARCHAR(20)   NULL,
    [in_scope]        NVARCHAR(10)   NULL,
    [term]            NVARCHAR(400)  NULL,
    [case_sensitive]  NVARCHAR(10)   NULL,
    source_file       NVARCHAR(260)  NOT NULL,
    loaded_at_utc     DATETIME2(0)   NOT NULL CONSTRAINT df_raw_alias_loaded DEFAULT SYSUTCDATETIME()
);
GO
