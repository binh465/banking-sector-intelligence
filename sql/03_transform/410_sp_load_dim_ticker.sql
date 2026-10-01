-- dw.sp_load_dim_ticker: sync dw.dim_ticker (SCD Type 2) with the config snapshot
-- (raw.raw_ticker_config + raw.raw_ticker_name_history).
--   version = (ticker, valid_from), the natural key of a row (uq_dim_ticker_version)
--   new version          -> insert, new ticker_key
--   changed version      -> update in place, ticker_key kept (e.g. valid_to closed by a new rename)
--   version not in config -> kept (facts may point to it); counted in the result
-- Same transaction rule as sp_load_dim_date.
USE BankingSectorIntelligence
GO

CREATE OR ALTER PROCEDURE dw.sp_load_dim_ticker
AS
BEGIN
	SET NOCOUNT ON
	SET XACT_ABORT ON;

	IF EXISTS (
		SELECT 1
		FROM raw.raw_ticker_name_history h
		JOIN raw.raw_ticker_config c ON c.[ticker] = h.[ticker]
		WHERE NULLIF(LTRIM(RTRIM(h.[valid_to])), N'') IS NULL
          AND LTRIM(RTRIM(h.[full_name])) <> LTRIM(RTRIM(c.[full_name])))
		THROW 50040, N'Current name in raw_ticker_name_history differs from raw_ticker_config',1;

	IF EXISTS (
		SELECT 1
		FROM raw.raw_ticker_name_history h
		WHERE NOT EXISTS (SELECT 1 FROM raw.raw_ticker_config c WHERE c.[ticker] = h.[ticker]))
			THROW 50041, N'raw_ticker_name_history has a ticker that is not in raw_ticker_config',1;

	DECLARE @own_tran bit = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
	DECLARE @actions TABLE (act NVARCHAR(10));

	BEGIN TRY
		IF @own_tran = 1 BEGIN TRANSACTION;

		WITH versions AS (
			 SELECT UPPER(LTRIM(RTRIM(h.[ticker])))                                         AS ticker,
                   LTRIM(RTRIM(h.[full_name]))                                             AS full_name,
                   LTRIM(RTRIM(c.[exchange]))                                              AS exchange,
                   COALESCE(CAST(NULLIF(LTRIM(RTRIM(h.[valid_from])), N'') AS date), '19000101') AS valid_from,
                   COALESCE(CAST(NULLIF(LTRIM(RTRIM(h.[valid_to]))  , N'') AS date), '99991231') AS valid_to
			FROM raw.raw_ticker_name_history h
			JOIN raw.raw_ticker_config c ON c.[ticker] = h.[ticker]
			UNION ALL
			SELECT UPPER(LTRIM(RTRIM(c.[ticker]))), LTRIM(RTRIM(c.[full_name])), LTRIM(RTRIM(c.[exchange])),
                   '19000101', '99991231'
			FROM raw.raw_ticker_config c
			WHERE NOT EXISTS (SELECT 1 FROM raw.raw_ticker_name_history h WHERE h.[ticker] = c.[ticker])
		), 
		 src AS (
            SELECT CAST(ticker    AS nvarchar(10))  AS ticker,
                   CAST(full_name AS nvarchar(200)) AS full_name,
                   CAST(exchange  AS nvarchar(10))  AS exchange,
                   CAST(valid_from AS date)         AS valid_from,
                   CAST(valid_to   AS date)         AS valid_to,
                   CAST(CASE WHEN valid_to = '99991231' THEN 1 ELSE 0 END AS bit) AS is_current
            FROM versions
        )
		MERGE dw.dim_ticker WITH (HOLDLOCK) AS tgt
		USING src
			ON tgt.ticker = src.ticker
			AND tgt.valid_from = src.valid_from
		WHEN MATCHED AND EXISTS (SELECT tgt.full_name, tgt.exchange, tgt.valid_to, tgt.is_current
								 EXCEPT
								 SELECT src.full_name, src.exchange, src.valid_to, src.is_current)
			THEN UPDATE SET tgt.full_name = src.full_name,
							tgt.exchange = src.exchange,
							tgt.valid_to = src.valid_to,
							tgt.is_current = src.is_current
		WHEN NOT MATCHED BY TARGET 
			THEN INSERT (ticker, full_name, exchange, valid_from, valid_to, is_current)
				VALUES (src.ticker, src.full_name, src.exchange, src.valid_from, src.valid_to, src.is_current)
		OUTPUT $action INTO @actions;

		IF @own_tran = 1 COMMIT TRANSACTION;
	END TRY
	BEGIN CATCH
		IF @own_tran = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
		THROW;
	END CATCH;

	SELECT N'dim_ticker'                                AS tbl,
           COUNT(CASE WHEN act = N'INSERT' THEN 1 END)  AS inserted,
           COUNT(CASE WHEN act = N'UPDATE' THEN 1 END)  AS updated,
           (SELECT COUNT(*) FROM dw.dim_ticker t
             WHERE NOT EXISTS (
                 SELECT 1
                 FROM raw.raw_ticker_name_history h
                 WHERE UPPER(LTRIM(RTRIM(h.[ticker]))) = t.ticker
                   AND COALESCE(CAST(NULLIF(LTRIM(RTRIM(h.[valid_from])), N'') AS date), '19000101') = t.valid_from)
               AND NOT EXISTS (
                 SELECT 1
                 FROM raw.raw_ticker_config c
                 WHERE UPPER(LTRIM(RTRIM(c.[ticker]))) = t.ticker
                   AND t.valid_from = '19000101'
                   AND NOT EXISTS (SELECT 1 FROM raw.raw_ticker_name_history h2 WHERE h2.[ticker] = c.[ticker]))
           )                                            AS versions_not_in_config
    FROM @actions;
END;
GO
