-- mart.v_price_session: close price per durable ticker per trading session.
-- One row per ticker per session. ticker is the durable key: STB keeps one series across its rename,
-- so every window function downstream partitions by ticker, never by ticker_key.
USE BankingSectorIntelligence
GO

CREATE OR ALTER VIEW mart.v_price_session
AS
SELECT t.ticker,
		d.date_key,
		d.full_date,
		d.session_seq,
		f.close_price
FROM dw.fact_price_daily f
JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
JOIN dw.dim_date d ON d.date_key = f.date_key
WHERE d.is_trading_day = 1;
GO