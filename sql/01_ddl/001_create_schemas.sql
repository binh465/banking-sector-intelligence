-- Creates the four layer schemas. Safe to re-run.
-- CREATE SCHEMA must be the only statement in its batch, so it cannot sit
-- directly under IF; EXEC runs it in its own batch.
USE BankingSectorIntelligence;
GO

IF SCHEMA_ID(N'raw')  IS NULL EXEC(N'CREATE SCHEMA raw  AUTHORIZATION dbo');  -- as delivered, string types
IF SCHEMA_ID(N'stg')  IS NULL EXEC(N'CREATE SCHEMA stg  AUTHORIZATION dbo');  -- typed, cleaned, filtered to window
IF SCHEMA_ID(N'dw')   IS NULL EXEC(N'CREATE SCHEMA dw   AUTHORIZATION dbo');  -- dimensions and facts
IF SCHEMA_ID(N'mart') IS NULL EXEC(N'CREATE SCHEMA mart AUTHORIZATION dbo');  -- analytical views for Power BI
GO
