USE BankingSectorIntelligence;

-- 1. Row count and date range per symbol.
--    MIN/MAX on text works here because ISO dates sort correctly as strings.
SELECT [symbol], COUNT(*) AS n, MIN([time]) AS first_bar, MAX([time]) AS last_bar
FROM raw.raw_price_daily GROUP BY [symbol] ORDER BY [symbol];

-- 2. Row count and date range of the calendar index.
SELECT [symbol], COUNT(*) AS n, MIN([time]) AS first_bar, MAX([time]) AS last_bar
FROM raw.raw_calendar GROUP BY [symbol];

-- 3. Duplicates on the natural key.
SELECT [symbol], [time], COUNT(*) AS n
FROM raw.raw_price_daily GROUP BY [symbol], [time] HAVING COUNT(*) > 1;

-- 4. Missing or 'nan' values in key columns.
SELECT COUNT(*) AS bad_rows
FROM raw.raw_price_daily
WHERE [symbol] IS NULL OR [time] IS NULL OR [close] IS NULL
   OR [close] IN (N'nan', N'NaN', N'None');

-- 5. Eyeball the text form of the numbers
SELECT TOP (5) [symbol], [time], [open], [close], [volume]
FROM raw.raw_price_daily WHERE [symbol] = N'VCB' ORDER BY [time] DESC;

-- 6. Before staging: can every value be typed, is every time exactly midnight, how many decimals?
--    Staging casts [time] to date and prices to DECIMAL(18,4), so this has to be clean first.
SELECT N'raw_price_daily' AS tbl,
       COUNT(*) AS n,
       SUM(CASE WHEN TRY_CONVERT(datetime2(0), [time]) IS NULL THEN 1 ELSE 0 END)                         AS time_bad,
       SUM(CASE WHEN CAST(TRY_CONVERT(datetime2(0), [time]) AS time) <> '00:00:00' THEN 1 ELSE 0 END)     AS time_not_midnight,
       SUM(CASE WHEN TRY_CONVERT(decimal(18,4), [open])  IS NULL OR TRY_CONVERT(decimal(18,4), [high]) IS NULL
                  OR TRY_CONVERT(decimal(18,4), [low])   IS NULL OR TRY_CONVERT(decimal(18,4), [close]) IS NULL
                THEN 1 ELSE 0 END)                                                                          AS price_bad,
       SUM(CASE WHEN [close] LIKE N'%e%' THEN 1 ELSE 0 END)                                               AS sci_notation,
       SUM(CASE WHEN TRY_CONVERT(bigint, [volume]) IS NULL THEN 1 ELSE 0 END)                             AS volume_bad,
       MAX(CASE WHEN CHARINDEX(N'.', [close]) > 0 THEN LEN([close]) - CHARINDEX(N'.', [close]) ELSE 0 END) AS max_decimals
FROM raw.raw_price_daily
UNION ALL
SELECT N'raw_calendar', COUNT(*),
       SUM(CASE WHEN TRY_CONVERT(datetime2(0), [time]) IS NULL THEN 1 ELSE 0 END),
       SUM(CASE WHEN CAST(TRY_CONVERT(datetime2(0), [time]) AS time) <> '00:00:00' THEN 1 ELSE 0 END),
       SUM(CASE WHEN TRY_CONVERT(decimal(18,4), [close]) IS NULL THEN 1 ELSE 0 END),
       SUM(CASE WHEN [close] LIKE N'%e%' THEN 1 ELSE 0 END),
       SUM(CASE WHEN TRY_CONVERT(bigint, [volume]) IS NULL THEN 1 ELSE 0 END),
       MAX(CASE WHEN CHARINDEX(N'.', [close]) > 0 THEN LEN([close]) - CHARINDEX(N'.', [close]) ELSE 0 END)
FROM raw.raw_calendar;
