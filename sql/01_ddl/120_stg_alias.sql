-- Staging tables for the alias config (config/aliases.yaml via raw.raw_alias).
--   stg_bank             one row per bank: the 10 in scope (bank_id = ticker) and the others
--   stg_alias            one row per term per bank; tier 1 = ticker, 2 = strong, 3 = weak
--   stg_alias_context    context words for tier 3
--   stg_alias_exclusion  phrases cut out of titles before matching; with when_title_contains set,
--                        only from titles containing that phrase (one condition per term)
-- A term may belong to one bank only (unique on term, case-insensitive under the database collation).
-- Loaded by sql/02_load/120_load_stg_alias.sql. Creates the tables only if they don't exist.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'stg.stg_bank', N'U') IS NULL
CREATE TABLE stg.stg_bank (
    bank_id   NVARCHAR(20)  NOT NULL,
    ticker    NVARCHAR(10)  NULL,
    in_scope  BIT           NOT NULL,
    CONSTRAINT pk_stg_bank PRIMARY KEY (bank_id),
    CONSTRAINT ck_stg_bank_scope CHECK ((in_scope = 1 AND ticker = bank_id) OR (in_scope = 0 AND ticker IS NULL))
);

IF OBJECT_ID(N'stg.stg_alias', N'U') IS NULL
CREATE TABLE stg.stg_alias (
    bank_id         NVARCHAR(20)   NOT NULL,
    term            NVARCHAR(200)  NOT NULL,
    tier            TINYINT        NOT NULL,
    case_sensitive  BIT            NOT NULL,
    CONSTRAINT pk_stg_alias PRIMARY KEY (bank_id, term),
    CONSTRAINT uq_stg_alias_term UNIQUE (term),
    CONSTRAINT fk_stg_alias_bank FOREIGN KEY (bank_id) REFERENCES stg.stg_bank (bank_id),
    CONSTRAINT ck_stg_alias_tier CHECK (tier IN (1, 2, 3))
);

IF OBJECT_ID(N'stg.stg_alias_context', N'U') IS NULL
CREATE TABLE stg.stg_alias_context (
    term  NVARCHAR(200)  NOT NULL,
    CONSTRAINT pk_stg_alias_context PRIMARY KEY (term)
);

IF OBJECT_ID(N'stg.stg_alias_exclusion', N'U') IS NULL
CREATE TABLE stg.stg_alias_exclusion (
    term            NVARCHAR(200)  NOT NULL,
    case_sensitive  BIT            NOT NULL,
    when_title_contains NVARCHAR(200) NULL,
    CONSTRAINT pk_stg_alias_exclusion PRIMARY KEY (term)
);

-- Column added 2026-10-07 (conditional exclusions); added here for a table created before that.
IF COL_LENGTH(N'stg.stg_alias_exclusion', N'when_title_contains') IS NULL
    ALTER TABLE stg.stg_alias_exclusion ADD when_title_contains NVARCHAR(200) NULL;
GO
