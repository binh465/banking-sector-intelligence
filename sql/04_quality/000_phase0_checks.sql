-- Phase 0 setup checks.

-- 1. Edition, version, server collation (compare with the DB collation below;
--    if they differ, #temp tables need COLLATE DATABASE_DEFAULT on text columns).
SELECT SERVERPROPERTY('Edition')        AS edition,
       SERVERPROPERTY('ProductVersion') AS product_version,
       SERVERPROPERTY('Collation')      AS server_collation;

-- 2. Expect 1 row: Vietnamese_100_CI_AS, SIMPLE.
SELECT name, collation_name, recovery_model_desc
FROM sys.databases
WHERE name = N'BankingSectorIntelligence';

-- 3. Expect exactly 4 rows.
SELECT name
FROM BankingSectorIntelligence.sys.schemas
WHERE name IN (N'raw', N'stg', N'dw', N'mart');

-- 4. Window arithmetic. Expect 2024-09-26.
SELECT DATEADD(DAY, 1, DATEADD(YEAR, -2, CAST('2026-09-25' AS date))) AS start_date;
