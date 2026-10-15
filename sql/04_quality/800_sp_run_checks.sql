-- dq.sp_run_checks: runs the data quality checks and appends one row per check to
-- dq.dq_check_result under a new dq.dq_run (decisions.md 2026-10-14).
-- No transaction around the run: results written before a failure stay, and the run is marked
-- 'failed', so a stopped run can be told from a run that never happened.
-- Checks are set-based INSERT ... SELECT statements; sample_keys holds up to 5 failing keys.
USE BankingSectorIntelligence;
GO

CREATE OR ALTER PROCEDURE dq.sp_run_checks
AS 
BEGIN
	SET NOCOUNT ON;

	DECLARE @run_id INT;
	INSERT INTO dq.dq_run (run_status) VALUES ('running');
	SET @run_id = SCOPE_IDENTITY();

	BEGIN TRY
		----------------------------------------------------------------- 1
		WITH expected AS (
			SELECT COUNT(*) AS n FROM dw.dim_date WHERE is_trading_day = 1
		),
		per_ticker AS (
			-- every ticker in dim_ticker, 0 when it has no price row
			SELECT t.ticker, COUNT(f.date_key) AS n
			FROM (SELECT DISTINCT ticker from dw.dim_ticker) t
			LEFT JOIN dw.dim_ticker v ON v.ticker = t.ticker
			LEFT JOIN dw.fact_price_daily f ON f.ticker_key = v.ticker_key
			GROUP BY t.ticker
		),
		bad AS (
			SELECT p.ticker, p.n
			FROM per_ticker p
			CROSS JOIN expected e WHERE p.n <> e.n
		)
		INSERT INTO dq.dq_check_result
              (run_id, check_name, layer, severity, checked_count, failed_count, sample_keys, description)
        SELECT @run_id, 'price_sessions_per_ticker', 'dw', 'ERROR',
               (SELECT COUNT(*) FROM per_ticker),
               (SELECT COUNT(*) FROM bad),
               (SELECT STRING_AGG(CONCAT(ticker, '=', n), '; ') WITHIN GROUP (ORDER BY ticker)
                FROM (SELECT TOP (5) ticker, n FROM bad ORDER BY ticker) s),
               N'Each ticker has one fact_price_daily row per trading day in dim_date (all ticker_key versions together).';
		
		----------------------------------------------------
		WITH bad AS (
			SELECT t.ticker, d.date_key, d.full_date
			FROM dw.fact_price_daily f
			INNER JOIN dw.dim_ticker t ON f.ticker_key = t.ticker_key
			INNER JOIN dw.dim_date d ON d.date_key = f.date_key
			WHERE d.is_trading_day = 0
		)
		INSERT INTO dq.dq_check_result
              (run_id, check_name, layer, severity, checked_count, failed_count, sample_keys, description)
        SELECT @run_id, 'price_on_non_trading_day', 'dw', 'ERROR',
               (SELECT COUNT(*) FROM dw.fact_price_daily),
               (SELECT COUNT(*) FROM bad),
               (SELECT STRING_AGG(key_sample, N'; ') WITHIN GROUP (ORDER BY ticker, full_date)
					FROM (
							SELECT TOP (5) ticker, full_date, CONCAT(
								ticker, N'|',
								CONVERT(NVARCHAR(10), full_date, 23) 
							) AS key_sample
							FROM bad
							ORDER BY ticker, full_date
					) AS s
				),
				N'No fact_price_daily row falls on a day with is_trading_day = 0.';

		----------------------------------
		WITH pair_counts AS (
			SELECT t.ticker, f.date_key, d.full_date, COUNT(*) AS row_count
			FROM dw.fact_price_daily f
			INNER JOIN dw.dim_ticker t ON f.ticker_key = t.ticker_key
			INNER JOIN dw.dim_date d ON f.date_key = d.date_key
			GROUP BY t.ticker, f.date_key, d.full_date
		), bad AS (
			SELECT ticker, date_key, full_date, row_count
			FROM pair_counts
			WHERE row_count > 1
		)
		INSERT INTO dq.dq_check_result
              (run_id, check_name, layer, severity, checked_count, failed_count, sample_keys, description)
		SELECT @run_id, 'price_duplicate_ticker_date', 'dw', 'ERROR',
               (SELECT COUNT(*) FROM pair_counts),
               (SELECT COUNT(*) FROM bad),
               (
					SELECT STRING_AGG(key_sample, N'; ') WITHIN GROUP (ORDER BY ticker, full_date)
					FROM (
						SELECT TOP(5) ticker, full_date,
							CONCAT(
									ticker, N'|', 
									CONVERT(NVARCHAR(10), full_date, 23), 
									N' (rows=', row_count, N')' 
								) AS key_sample
						FROM bad
						ORDER BY ticker, full_date
					) AS s
			   ),
			    N'Each ticker/date pair must have at most one fact_price_daily row across all ticker_key versions.';
		
		--------------------------------------------------
		WITH constraints AS (
			SELECT N'FK' AS constraint_type,
				t.name AS table_name,
				fk.name AS constraint_name,
				fk.is_disabled,
				fk.is_not_trusted
			FROM sys.foreign_keys fk
			INNER JOIN sys.tables t ON t.object_id = fk.parent_object_id
			WHERE SCHEMA_NAME(t.schema_id) = N'dw'

			UNION ALL

			SELECT N'CHECK' AS constraint_type,
				t.name AS table_name,
				cc.name AS constraint_name,
				cc.is_disabled,
				cc.is_not_trusted
			FROM sys.check_constraints cc
			INNER JOIN sys.tables t ON t.object_id = cc.parent_object_id
			WHERE SCHEMA_NAME(t.schema_id) = N'dw'
		), 
		bad AS (
			SELECT constraint_type, table_name, constraint_name, is_disabled, is_not_trusted
			FROM constraints
			WHERE is_disabled = 1 OR is_not_trusted = 1
		)
		INSERT INTO dq.dq_check_result
              (run_id, check_name, layer, severity, checked_count, failed_count, sample_keys, description)

		 SELECT @run_id, 'dw_constraints_trusted', 'dw', 'ERROR',
            (SELECT COUNT(*) FROM constraints),
            (SELECT COUNT(*) FROM bad),
            (
                SELECT STRING_AGG(key_sample, N'; ') WITHIN GROUP (ORDER BY constraint_type, table_name, constraint_name)
                FROM (
                    SELECT TOP (5)
                        constraint_type,
                        table_name,
                        constraint_name,
                        CONCAT(
                            constraint_type, N':',
                            table_name, N'.', constraint_name,
                            N' [disabled=', is_disabled,
                            N', not_trusted=', is_not_trusted, N']'
                        ) AS key_sample
                    FROM bad
                    ORDER BY constraint_type, table_name, constraint_name
                ) AS s
            ),
            N'All foreign-key and CHECK constraints on DW tables must be enabled and trusted.';

		------------------------------------
		WITH trading_sessions AS (
			SELECT full_date, session_seq, ROW_NUMBER() OVER (ORDER BY full_date) AS expected_seq
			FROM dw.dim_date
			WHERE is_trading_day = 1
		),
		bad AS (
			SELECT full_date, session_seq, expected_seq
			FROM trading_sessions
			WHERE session_seq IS NULL OR session_seq <> expected_seq
		)
		INSERT INTO dq.dq_check_result
            (run_id, check_name, layer, severity,
             checked_count, failed_count, sample_keys, description)
        SELECT @run_id, 'dim_date_session_seq_gap', 'dw', 'ERROR',
            (SELECT COUNT(*) FROM trading_sessions),
            (SELECT COUNT(*) FROM bad),
            (
                SELECT STRING_AGG(key_sample, N'; ') WITHIN GROUP (ORDER BY full_date)
                FROM (
                    SELECT TOP (5) full_date,
                        CONCAT(
                            CONVERT(NVARCHAR(10), full_date, 23),
                            N' (session_seq=', session_seq,
                            N', expected=', expected_seq, N')'
                        ) AS key_sample
                    FROM bad
                    ORDER BY full_date
                ) AS s
            ),
            N'Trading-day session_seq must form a continuous sequence starting at 1 when ordered by full_date.';
		---------------------------------------
		WITH returns AS (
			SELECT ticker, session_seq, full_date, ret
			FROM mart.v_return_daily
			WHERE ret IS NOT NULL
		),
		bad AS (
			SELECT ticker, session_seq, full_date, ret
			FROM returns
			WHERE ABS(ret) > 0.07 AND ABS(ret) <= 0.075 
		)
		INSERT INTO dq.dq_check_result
            (run_id, check_name, layer, severity,
             checked_count, failed_count, sample_keys, description)
		SELECT @run_id,  'return_band_within_tolerance', 'mart', 'WARN',
            (SELECT COUNT(*) FROM returns),
            (SELECT COUNT(*) FROM bad),
			(
				SELECT STRING_AGG(key_sample, N'; ') WITHIN GROUP (ORDER BY ticker, session_seq)
				FROM (
					SELECT TOP(5) ticker, session_seq, 
						CONCAT(ticker, N'|', CONVERT(NVARCHAR(10), full_date, 23), N' (ret=', FORMAT(ret, 'P2', 'en-US'), N')'
						) AS key_sample
					FROM bad
					ORDER BY ticker, session_seq
				) AS s
			),
			N'Warn when ABS(ret) is greater than 7% and at most 7.5%, using the Phase 2 thresholds.';

		----------------------------------------
		WITH returns AS (
			SELECT ticker, session_seq, full_date, ret
			FROM mart.v_return_daily
			WHERE ret IS NOT NULL
		),
		bad AS (
			SELECT ticker, session_seq, full_date, ret
			FROM returns
			WHERE ABS(ret) > 0.075
		)
		INSERT INTO dq.dq_check_result
            (run_id, check_name, layer, severity,
             checked_count, failed_count, sample_keys, description)
		SELECT @run_id,  'return_band_exceeded', 'mart', 'ERROR',
            (SELECT COUNT(*) FROM returns),
            (SELECT COUNT(*) FROM bad),
			(
				SELECT STRING_AGG(key_sample, N'; ') WITHIN GROUP (ORDER BY ticker, session_seq)
				FROM (
					SELECT TOP(5) ticker, session_seq, 
						CONCAT(ticker, N'|', CONVERT(NVARCHAR(10), full_date, 23), N' (ret=', FORMAT(ret, 'P2', 'en-US'), N')'
						) AS key_sample
					FROM bad
					ORDER BY ticker, session_seq
				) AS s
			),
			N'Error when ABS(ret) exceeds 7.5%, using the Phase 2 threshold.';
		----------------------------------------
		WITH bad AS (
			SELECT t.ticker, f.article_key, pd.full_date
			FROM dw.fact_news f
			INNER JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
			INNER JOIN dw.dim_date AS pd ON pd.date_key = f.publish_date_key
			WHERE pd.full_date NOT BETWEEN t.valid_from AND t.valid_to
		)
		INSERT INTO dq.dq_check_result
            (run_id, check_name, layer, severity,
             checked_count, failed_count, sample_keys, description)
		SELECT @run_id,  'news_ticker_version', 'dw', 'ERROR',
            (SELECT COUNT(*) FROM dw.fact_news),
            (SELECT COUNT(*) FROM bad),
			(
				SELECT STRING_AGG(key_sample, N'; ') WITHIN GROUP (ORDER BY ticker, article_key, full_date)
				FROM (
					SELECT TOP(5) ticker, article_key, full_date,
						CONCAT(ticker, N'|', article_key, N'|', CONVERT(NVARCHAR(10), full_date, 23)
						) AS key_sample
					FROM bad
					ORDER BY ticker, article_key, full_date
				) AS s
			),
			 N'Each fact_news row must reference a dim_ticker version valid on its publish date.';
		------------------------------------------
		;WITH raw_rows AS (
			SELECT d.ticker, d.trade_date,
				TRY_CONVERT(DECIMAL(18,4), p.[open]) AS open_price,
				TRY_CONVERT(DECIMAL(18,4), p.[high])  AS high_price,
                TRY_CONVERT(DECIMAL(18,4), p.[low])   AS low_price,
                TRY_CONVERT(DECIMAL(18,4), p.[close]) AS close_price,
                TRY_CONVERT(BIGINT, p.[volume])       AS volume
			FROM raw.raw_price_daily p
			CROSS APPLY (
				SELECT UPPER(LTRIM(RTRIM(p.[symbol]))) AS ticker,
				CAST(TRY_CONVERT(DATETIME2(0), p.[time]) AS DATE) AS trade_date
			) AS d
			INNER JOIN raw.raw_ticker_config c ON c.ticker = d.ticker
			CROSS JOIN stg.stg_scope s
			WHERE d.trade_date BETWEEN s.start_date AND s.end_date
		),
		stg_rows AS (
			SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume
			FROM stg.stg_price_daily
		),
		raw_minus_stg AS (
			SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume
			FROM raw_rows
			EXCEPT 
			SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume
			FROM stg_rows
		),
		stg_minus_raw AS (
			SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume
            FROM stg_rows
            EXCEPT
            SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume
            FROM raw_rows
		),
		bad AS (
			SELECT ticker, trade_date FROM raw_minus_stg
            UNION
            SELECT ticker, trade_date FROM stg_minus_raw
		),
		 all_keys AS (
            SELECT ticker, trade_date FROM raw_rows
            UNION
            SELECT ticker, trade_date FROM stg_rows
        )
		INSERT INTO dq.dq_check_result
              (run_id, check_name, layer, severity, checked_count, failed_count, sample_keys, description)
        SELECT @run_id, 'reconcile_price_raw_stg', 'stg', 'ERROR',
               (SELECT COUNT(*) FROM all_keys),
               (SELECT COUNT(*) FROM bad),
               (SELECT STRING_AGG(key_sample, N'; ') WITHIN GROUP (ORDER BY ticker, trade_date)
                FROM (
                    SELECT TOP (5) ticker, trade_date,
                           CONCAT(ticker, N'|', CONVERT(NVARCHAR(10), trade_date, 23)) AS key_sample
                    FROM bad
                    ORDER BY ticker, trade_date
                ) AS s),
               N'stg_price_daily must match configured in-window raw_price_daily by ticker/date and OHLCV values.';
		--------------------------------------------
		;WITH stg_rows AS (
			SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume
			FROM stg.stg_price_daily
		),
		dw_rows AS (
			SELECT t.ticker, d.full_date AS trade_date,
				   f.open_price, f.high_price, f.low_price, f.close_price, f.volume
			FROM dw.fact_price_daily f
			INNER JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
			INNER JOIN dw.dim_date d   ON d.date_key   = f.date_key
		),
		stg_minus_dw AS (
			SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume FROM stg_rows
			EXCEPT
			SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume FROM dw_rows
		),
		dw_minus_stg AS (
			SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume FROM dw_rows
			EXCEPT
			SELECT ticker, trade_date, open_price, high_price, low_price, close_price, volume FROM stg_rows
		),
		bad AS (
			SELECT ticker, trade_date FROM stg_minus_dw
			UNION
			SELECT ticker, trade_date FROM dw_minus_stg
		),
		all_keys AS (
			SELECT ticker, trade_date FROM stg_rows
			UNION
			SELECT ticker, trade_date FROM dw_rows
		)
		INSERT INTO dq.dq_check_result
			  (run_id, check_name, layer, severity, checked_count, failed_count, sample_keys, description)
		SELECT @run_id, 'reconcile_price_stg_dw', 'dw', 'ERROR',
			   (SELECT COUNT(*) FROM all_keys),
			   (SELECT COUNT(*) FROM bad),
			   (SELECT STRING_AGG(key_sample, N'; ') WITHIN GROUP (ORDER BY ticker, trade_date)
				FROM (
					SELECT TOP (5) ticker, trade_date,
						   CONCAT(ticker, N'|', CONVERT(NVARCHAR(10), trade_date, 23)) AS key_sample
					FROM bad
					ORDER BY ticker, trade_date
				) AS s),
			   N'fact_price_daily must match stg_price_daily by ticker/date and OHLCV values (all ticker_key versions together).';
		--------------------------------------------
		;WITH src AS (
			SELECT m.article_key, b.ticker
			FROM stg.stg_article_bank_match m
			INNER JOIN stg.stg_bank b ON b.bank_id = m.bank_id AND b.in_scope = 1

			UNION ALL

			SELECT a.article_key, n.ticker
			FROM stg.stg_ticker_news n
			INNER JOIN dw.dim_article a ON a.url = n.url
			WHERE n.item_kind = 'disclosure'
		),
		src_in_window AS (
			SELECT s.article_key, s.ticker
			FROM src AS s
			INNER JOIN dw.dim_article a ON a.article_key = s.article_key
			WHERE EXISTS (
				SELECT 1
				FROM dw.dim_date d
				WHERE d.full_date = CAST(a.publish_time_local AS DATE)
			)
		),
		fact AS (
			SELECT f.article_key, t.ticker
			FROM dw.fact_news f
			INNER JOIN dw.dim_ticker t ON t.ticker_key = f.ticker_key
		),
		source_minus_fact AS (
            SELECT article_key, ticker FROM src_in_window
            EXCEPT
            SELECT article_key, ticker FROM fact
        ),
        fact_minus_source AS (
            SELECT article_key, ticker FROM fact
            EXCEPT
            SELECT article_key, ticker FROM src_in_window
        ),
        bad AS (
            SELECT article_key, ticker FROM source_minus_fact
            UNION
            SELECT article_key, ticker FROM fact_minus_source
        ),
        all_pairs AS (
            SELECT article_key, ticker FROM src_in_window
            UNION
            SELECT article_key, ticker FROM fact
        )
        INSERT INTO dq.dq_check_result
              (run_id, check_name, layer, severity, checked_count, failed_count, sample_keys, description)
        SELECT @run_id, 'reconcile_news_stg_dw', 'dw', 'ERROR',
               (SELECT COUNT(*) FROM all_pairs),
               (SELECT COUNT(*) FROM bad),
               (SELECT STRING_AGG(key_sample, N'; ') WITHIN GROUP (ORDER BY ticker, article_key)
                FROM (
                    SELECT TOP (5) ticker, article_key,
                           CONCAT(ticker, N'|', article_key) AS key_sample
                    FROM bad
                    ORDER BY ticker, article_key
                ) AS s),
               N'In-window (article_key, ticker) pairs must match between staging expectations and fact_news in both directions.';
		--------------------------------------------
		UPDATE dq.dq_run SET run_status = 'completed', finished_at_utc = SYSUTCDATETIME()
		WHERE run_id = @run_id;
	END TRY

	BEGIN CATCH
		IF XACT_STATE() <> -1
			UPDATE dq.dq_run SET run_status = 'failed', finished_at_utc = SYSUTCDATETIME()
			WHERE run_id = @run_id;
		THROW;
	END CATCH;
	
	SELECT check_name, layer, severity, checked_count, failed_count, check_status, sample_keys
	FROM dq.dq_check_result
	WHERE run_id = @run_id
	ORDER BY CASE check_status WHEN 'ERROR' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END, check_name;
END;
GO