USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_pbi_date AS
SELECT date_key
      ,full_date
      ,[year]
      ,[quarter]
      ,[month]
      ,month_start
      ,day_of_month
      ,iso_week
      ,day_of_week
      ,is_weekend
      ,is_trading_day
      ,session_seq
FROM dw.dim_date;
GO