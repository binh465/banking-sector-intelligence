-- Load stg.stg_precision_label from raw.raw_precision_label (docs/precision_sample.csv).
-- The checks stop the load before anything is written; labels are fixed in the CSV, not here.
-- Rules behind the checks: decisions.md, 2026-10-03 to 2026-10-05 (precision sample, labelling cases).
USE BankingSectorIntelligence;
GO
SET XACT_ABORT ON;

-- Every row labelled with 0 or 1.
IF EXISTS (SELECT 1 FROM raw.raw_precision_label
           WHERE ISNULL(LTRIM(RTRIM(is_correct)), N'') NOT IN (N'0', N'1')
              OR ISNULL(LTRIM(RTRIM(is_main_subject)), N'') NOT IN (N'0', N'1'))
    THROW 50100, N'A row has a missing or invalid label (expected 0 or 1)', 1;

-- A wrong match cannot be the main subject.
IF EXISTS (SELECT 1 FROM raw.raw_precision_label
           WHERE LTRIM(RTRIM(is_correct)) = N'0' AND LTRIM(RTRIM(is_main_subject)) = N'1')
    THROW 50101, N'is_correct = 0 with is_main_subject = 1', 1;

-- One row per pair.
IF EXISTS (SELECT 1 FROM raw.raw_precision_label GROUP BY url, ticker HAVING COUNT(*) > 1)
    THROW 50102, N'Duplicate (url, ticker) in the label file', 1;

-- One stratum size per stratum.
IF EXISTS (SELECT 1 FROM raw.raw_precision_label GROUP BY stratum HAVING COUNT(DISTINCT stratum_pairs) > 1)
    THROW 50103, N'A stratum has more than one stratum_pairs value', 1;

-- Note case codes: known codes only, and consistent with the labels.
WITH n AS (
    SELECT is_correct, is_main_subject,
           LTRIM(RTRIM(LEFT(note, CHARINDEX(N':', note + N':') - 1))) AS case_code
    FROM raw.raw_precision_label
    WHERE NULLIF(LTRIM(RTRIM(note)), N'') IS NOT NULL
)
SELECT case_code, is_correct, is_main_subject INTO #codes FROM n;

IF EXISTS (SELECT 1 FROM #codes
           WHERE case_code NOT IN (N'A', N'B', N'C1', N'C2', N'C3', N'D', N'E', N'F', N'G', N'H'))
    THROW 50104, N'A note starts with an unknown case code', 1;

IF EXISTS (SELECT 1 FROM #codes
           WHERE (case_code IN (N'A', N'C3', N'D') AND is_main_subject = N'1')
              OR (case_code IN (N'B', N'E', N'H') AND is_main_subject = N'0')
              OR (case_code = N'F' AND is_correct = N'1'))
    THROW 50105, N'A note case code contradicts the labels', 1;

DROP TABLE #codes;

BEGIN TRANSACTION;

TRUNCATE TABLE stg.stg_precision_label;

INSERT INTO stg.stg_precision_label (url, ticker, label_order, stratum, stratum_pairs, matched_term,
                                     is_correct, is_main_subject, case_code, note)
SELECT LTRIM(RTRIM(url)),
       LTRIM(RTRIM(ticker)),
       CAST(label_order AS smallint),
       LTRIM(RTRIM(stratum)),
       CAST(stratum_pairs AS int),
       NULLIF(LTRIM(RTRIM(matched_term)), N''),
       CAST(LTRIM(RTRIM(is_correct)) AS bit),
       CAST(LTRIM(RTRIM(is_main_subject)) AS bit),
       CASE WHEN NULLIF(LTRIM(RTRIM(note)), N'') IS NOT NULL
            THEN LTRIM(RTRIM(LEFT(note, CHARINDEX(N':', note + N':') - 1))) END,
       NULLIF(LTRIM(RTRIM(note)), N'')
FROM raw.raw_precision_label;

COMMIT TRANSACTION;

-- Result: rows per stratum, and pairs no longer in the current sample view. The second number is 0
-- while the matching rules are the ones the sample was drawn from; after a rule change it shows how
-- many labelled pairs left the population.
SELECT l.stratum, COUNT(*) AS labelled, MAX(l.stratum_pairs) AS stratum_pairs,
       SUM(CASE WHEN v.url IS NULL THEN 1 ELSE 0 END) AS not_in_current_sample
FROM stg.stg_precision_label l
LEFT JOIN stg.v_precision_sample v ON v.url = l.url AND v.ticker = l.ticker
GROUP BY l.stratum
ORDER BY l.stratum;
GO
