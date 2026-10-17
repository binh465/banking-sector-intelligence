USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_pbi_ticker AS
SELECT ticker, full_name, exchange
FROM dw.dim_ticker
WHERE is_current = 1;
GO