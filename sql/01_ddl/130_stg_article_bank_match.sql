-- stg.stg_article_bank_match: which banks a CafeF article title names, per the alias rules.
-- One row per article per bank (in scope or not). Built by sql/03_transform/500_match_articles.sql.
--   best_tier      lowest tier that matched: 1 ticker, 2 strong alias, 3 weak alias + context word
--   matched_term   the term behind best_tier (first by term when several match at that tier)
--   terms_matched  how many alias terms of this bank matched the title
-- Creates the table only if it doesn't exist.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'stg.stg_article_bank_match', N'U') IS NULL
CREATE TABLE stg.stg_article_bank_match (
    article_key    INT            NOT NULL,
    bank_id        NVARCHAR(20)   NOT NULL,
    best_tier      TINYINT        NOT NULL,
    matched_term   NVARCHAR(200)  NOT NULL,
    terms_matched  SMALLINT       NOT NULL,
    CONSTRAINT pk_stg_article_bank_match PRIMARY KEY (article_key, bank_id),
    CONSTRAINT ck_stg_article_bank_match_tier CHECK (best_tier IN (1, 2, 3))
);
GO
