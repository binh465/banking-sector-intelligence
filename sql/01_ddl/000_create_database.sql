-- Creates the project database.
-- Collation: Vietnamese, case-insensitive, accent-sensitive.
--   CI: 'vcb' = 'VCB' in ticker matching.
--   AS: 'Ngân' <> 'Ngan'; accent-insensitive would merge distinct Vietnamese
--       syllables and raise false matches in the alias rules (Phase 5).
-- All text columns in this project use NVARCHAR.
--
-- Existence is not enough: if the database already exists with another
-- collation, fail loudly instead of silently skipping creation.
IF DB_ID(N'BankingSectorIntelligence') IS NULL
    CREATE DATABASE BankingSectorIntelligence COLLATE Vietnamese_100_CI_AS;
ELSE IF CAST(DATABASEPROPERTYEX(N'BankingSectorIntelligence', 'Collation') AS nvarchar(128)) <> N'Vietnamese_100_CI_AS'
BEGIN
    THROW 50001, N'BankingSectorIntelligence exists with a collation other than Vietnamese_100_CI_AS. Fix it before continuing.', 1;
END
GO

-- Dev database: no point-in-time restore needed, keep the log small.
ALTER DATABASE BankingSectorIntelligence SET RECOVERY SIMPLE;
GO
