-- Load the alias staging tables from raw.raw_alias (config/aliases.yaml) and raw.raw_ticker_config.
-- Tier 1 rows (tickers) come from the ticker config, not from aliases.yaml.
-- Full reload in one transaction; the checks below stop the load on a config that contradicts itself.
USE BankingSectorIntelligence;
GO
SET XACT_ABORT ON;

IF EXISTS (SELECT 1 FROM raw.raw_alias WHERE [kind] NOT IN (N'context', N'exclusion', N'strong', N'weak'))
    THROW 50070, N'raw.raw_alias has an unknown kind', 1;

-- The banks marked in scope in aliases.yaml must be exactly the tickers in tickers.yaml.
IF EXISTS (SELECT [bank_id] FROM raw.raw_alias WHERE [kind] IN (N'strong', N'weak') AND [in_scope] = N'1'
           EXCEPT
           SELECT [ticker] FROM raw.raw_ticker_config)
   OR EXISTS (SELECT [ticker] FROM raw.raw_ticker_config
              EXCEPT
              SELECT [bank_id] FROM raw.raw_alias WHERE [kind] IN (N'strong', N'weak') AND [in_scope] = N'1')
    THROW 50071, N'In-scope banks in aliases.yaml differ from the tickers in tickers.yaml', 1;

-- One bank, one in_scope value.
IF EXISTS (SELECT [bank_id] FROM raw.raw_alias WHERE [kind] IN (N'strong', N'weak')
           GROUP BY [bank_id] HAVING COUNT(DISTINCT [in_scope]) > 1)
    THROW 50072, N'A bank in aliases.yaml has more than one in_scope value', 1;

-- A phrase can't be both a bank alias and an exclusion.
IF EXISTS (SELECT 1 FROM raw.raw_alias a JOIN raw.raw_alias x ON x.[term] = a.[term]
           WHERE a.[kind] IN (N'strong', N'weak') AND x.[kind] = N'exclusion')
    THROW 50073, N'A term is both an alias and an exclusion', 1;

BEGIN TRANSACTION;

DELETE FROM stg.stg_alias;            -- child first (foreign key to stg_bank)
DELETE FROM stg.stg_bank;
TRUNCATE TABLE stg.stg_alias_context;
TRUNCATE TABLE stg.stg_alias_exclusion;

INSERT INTO stg.stg_bank (bank_id, ticker, in_scope)
SELECT DISTINCT LTRIM(RTRIM([bank_id])),
       CASE WHEN [in_scope] = N'1' THEN LTRIM(RTRIM([bank_id])) END,
       CAST([in_scope] AS bit)
FROM raw.raw_alias
WHERE [kind] IN (N'strong', N'weak');

-- tier 1: tickers of the banks in scope, always case-sensitive
INSERT INTO stg.stg_alias (bank_id, term, tier, case_sensitive)
SELECT LTRIM(RTRIM([ticker])), LTRIM(RTRIM([ticker])), 1, 1
FROM raw.raw_ticker_config;

-- tiers 2 and 3. A ticker written again as an alias (e.g. ACB) would hit the unique key on term.
INSERT INTO stg.stg_alias (bank_id, term, tier, case_sensitive)
SELECT LTRIM(RTRIM([bank_id])), LTRIM(RTRIM([term])),
       CASE [kind] WHEN N'strong' THEN 2 ELSE 3 END,
       CAST([case_sensitive] AS bit)
FROM raw.raw_alias
WHERE [kind] IN (N'strong', N'weak');

INSERT INTO stg.stg_alias_context (term)
SELECT LTRIM(RTRIM([term])) FROM raw.raw_alias WHERE [kind] = N'context';

INSERT INTO stg.stg_alias_exclusion (term, case_sensitive)
SELECT LTRIM(RTRIM([term])), CAST([case_sensitive] AS bit) FROM raw.raw_alias WHERE [kind] = N'exclusion';

COMMIT TRANSACTION;

SELECT N'stg_bank' AS tbl, COUNT(*) AS n FROM stg.stg_bank
UNION ALL SELECT N'stg_alias', COUNT(*) FROM stg.stg_alias
UNION ALL SELECT N'stg_alias_context', COUNT(*) FROM stg.stg_alias_context
UNION ALL SELECT N'stg_alias_exclusion', COUNT(*) FROM stg.stg_alias_exclusion;

SELECT b.in_scope, a.tier, COUNT(*) AS terms, COUNT(DISTINCT a.bank_id) AS banks
FROM stg.stg_alias a JOIN stg.stg_bank b ON b.bank_id = a.bank_id
GROUP BY b.in_scope, a.tier
ORDER BY b.in_scope DESC, a.tier;
GO
