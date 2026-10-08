-- mart.v_ticker_index: base-100 index per ticker, 100 at the first session, compounded from ret.
-- Same method as v_sector_index so the two series are comparable (used by v_relative_strength).
-- Partitioned by ticker, the durable code: a rename creates a second ticker_key, not a second series.
-- The first session has no return; it counts as 0 so each index starts at 100.
USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_ticker_index
AS
SELECT ticker, date_key, full_date, session_seq, close_price, prev_close, ret,
	100 * EXP(SUM(
				LOG(1 + ISNULL(ret, 0))
				 ) OVER ( PARTITION BY ticker
					ORDER BY session_seq
					ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
				 )
			 ) AS ticker_index
FROM mart.v_return_daily
