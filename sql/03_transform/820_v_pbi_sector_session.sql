USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_pbi_sector_session AS
SELECT date_key, session_seq, sector_ret, sector_index
FROM mart.v_sector_index;
GO