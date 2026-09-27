-- DESTRUCTIVE: drops the project database so 000/001 can rebuild it from zero.
-- Only for use while the database holds nothing that cannot be re-created.
-- Check first: the query below must return 0 before you run the DROP.
USE BankingSectorIntelligence;
SELECT COUNT(*) AS user_objects FROM sys.objects WHERE is_ms_shipped = 0;
GO

-- Run the rest only after the count above is 0.
-- USE master;
-- ALTER DATABASE BankingSectorIntelligence SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
-- DROP DATABASE BankingSectorIntelligence;
-- GO
