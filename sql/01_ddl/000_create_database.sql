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
GO

-- USE opens the database first. While a database is closed (AUTO_CLOSE), DATABASEPROPERTYEX and
-- sys.databases.collation_name both return NULL, and NULL <> '...' is not true, so a check run on
-- a closed database would pass without a word. A NULL that is still there after USE also fails.
USE BankingSectorIntelligence;
GO
DECLARE @collation nvarchar(128) = CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS nvarchar(128));
IF @collation IS NULL OR @collation <> N'Vietnamese_100_CI_AS'
BEGIN
    DECLARE @msg nvarchar(400) = CONCAT(DB_NAME(), N' has collation ', ISNULL(@collation, N'(not readable)'),
                                        N', expected Vietnamese_100_CI_AS. Fix it before continuing.');
    THROW 50001, @msg, 1;
END
GO
USE master;
GO

-- Dev database: no point-in-time restore needed, keep the log small.
ALTER DATABASE BankingSectorIntelligence SET RECOVERY SIMPLE;
-- Express creates databases with AUTO_CLOSE ON: the database closes after the last connection and
-- opens again on the next one. Off, so it stays open and its properties stay readable.
ALTER DATABASE BankingSectorIntelligence SET AUTO_CLOSE OFF;
GO
