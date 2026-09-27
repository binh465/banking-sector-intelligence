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