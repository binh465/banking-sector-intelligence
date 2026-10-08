-- mart.v_sector_index: equal-weight sector index, base 100 at the first session of the window.
-- index(s) = 100 * product over sessions 2..s of (1 + sector_ret), computed as EXP(SUM(LOG(1 + r))).
-- Session 1 has no return; ISNULL(..., 0) makes it contribute LOG(1) = 0, so the index starts at 100.
-- Only session 1 is expected to have a NULL sector_ret (see v_sector_return.tickers_with_return);
-- a NULL later in the series would be treated as a flat session, so the check on NULL sessions matters.
-- ROWS frame is explicit: the default frame with ORDER BY is RANGE, which uses an on-disk worktable.
USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_sector_index
AS
SELECT session_seq, date_key, full_date, sector_ret,
	100 * EXP(SUM(
				LOG(1 + ISNULL(sector_ret, 0))
				 ) OVER (
					ORDER BY session_seq
					ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
				 )
			 ) AS sector_index
FROM mart.v_sector_return;
GO