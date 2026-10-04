-- Phase 5, step 1: how do CafeF titles actually name banks?
-- Read-only exploration on dw.dim_article (articles only; disclosures already carry their ticker).
-- The output is read by hand to build config/aliases.yaml; nothing here is loaded anywhere.
-- Titles are split into words once (#tok), then three views:
--   1. words containing "bank"            -> brand names (Vietcombank, VPBank, ... and banks outside the 10)
--   2. the 1-3 words after "ngân hàng"    -> how the Vietnamese names are written
--   3. upper-case words of 2-5 letters    -> tickers and acronyms (VCB, BIDV, MSB, ...), case-sensitive
USE BankingSectorIntelligence;
SET NOCOUNT ON;

-- Punctuation that sticks to words becomes a space. TRANSLATE needs both strings the same length.
DECLARE @punct NVARCHAR(40) = N',.:;!?()"“”‘’[]…|';
DECLARE @space NVARCHAR(40) = REPLICATE(N' ', LEN(@punct));

IF OBJECT_ID(N'tempdb..#tok') IS NOT NULL DROP TABLE #tok;

-- SELECT INTO keeps the source column's collation (Vietnamese_100_CI_AS), not tempdb's.
SELECT a.article_key,
       CAST(s.ordinal AS int) AS pos,
       s.value                AS w
INTO #tok
FROM dw.dim_article a
CROSS APPLY STRING_SPLIT(TRANSLATE(a.title, @punct, @space), N' ', 1) s   -- 1 = return the word position
WHERE a.item_type = 'article'
  AND s.value <> N'';

CREATE CLUSTERED INDEX cx_tok ON #tok (article_key, pos);

SELECT COUNT(*) AS words, COUNT(DISTINCT article_key) AS titles FROM #tok;

-- 1. Words containing "bank" (case-insensitive), with how many titles use each.
SELECT TOP (80)
       MIN(w COLLATE Latin1_General_BIN2) AS example_spelling,
       COUNT(DISTINCT w COLLATE Latin1_General_BIN2) AS spellings,
       COUNT(DISTINCT article_key) AS titles
FROM #tok
WHERE w LIKE N'%bank%'
GROUP BY w
ORDER BY titles DESC;

-- 2. What follows "ngân hàng": the next 1, 2 and 3 words. Grouped case-insensitively.
WITH nh AS (
    SELECT t1.article_key, t1.pos
    FROM #tok t1
    JOIN #tok t2 ON t2.article_key = t1.article_key AND t2.pos = t1.pos + 1
    WHERE t1.w = N'ngân' AND t2.w = N'hàng'
),
nxt AS (
    SELECT nh.article_key,
           w3.w AS w1, w4.w AS w2, w5.w AS w3
    FROM nh
    LEFT JOIN #tok w3 ON w3.article_key = nh.article_key AND w3.pos = nh.pos + 2
    LEFT JOIN #tok w4 ON w4.article_key = nh.article_key AND w4.pos = nh.pos + 3
    LEFT JOIN #tok w5 ON w5.article_key = nh.article_key AND w5.pos = nh.pos + 4
)
SELECT TOP (150) N'1 word' AS n, w1 AS words, COUNT(DISTINCT article_key) AS titles
FROM nxt WHERE w1 IS NOT NULL
GROUP BY w1
ORDER BY titles DESC;

WITH nh AS (
    SELECT t1.article_key, t1.pos
    FROM #tok t1
    JOIN #tok t2 ON t2.article_key = t1.article_key AND t2.pos = t1.pos + 1
    WHERE t1.w = N'ngân' AND t2.w = N'hàng'
),
nxt AS (
    SELECT nh.article_key,
           w3.w AS w1, w4.w AS w2, w5.w AS w3
    FROM nh
    LEFT JOIN #tok w3 ON w3.article_key = nh.article_key AND w3.pos = nh.pos + 2
    LEFT JOIN #tok w4 ON w4.article_key = nh.article_key AND w4.pos = nh.pos + 3
    LEFT JOIN #tok w5 ON w5.article_key = nh.article_key AND w5.pos = nh.pos + 4
)
SELECT TOP (150) N'2 words' AS n, CONCAT(w1, N' ', w2) AS words, COUNT(DISTINCT article_key) AS titles
FROM nxt WHERE w2 IS NOT NULL
GROUP BY CONCAT(w1, N' ', w2)
ORDER BY titles DESC;

WITH nh AS (
    SELECT t1.article_key, t1.pos
    FROM #tok t1
    JOIN #tok t2 ON t2.article_key = t1.article_key AND t2.pos = t1.pos + 1
    WHERE t1.w = N'ngân' AND t2.w = N'hàng'
),
nxt AS (
    SELECT nh.article_key,
           w3.w AS w1, w4.w AS w2, w5.w AS w3
    FROM nh
    LEFT JOIN #tok w3 ON w3.article_key = nh.article_key AND w3.pos = nh.pos + 2
    LEFT JOIN #tok w4 ON w4.article_key = nh.article_key AND w4.pos = nh.pos + 3
    LEFT JOIN #tok w5 ON w5.article_key = nh.article_key AND w5.pos = nh.pos + 4
)
SELECT TOP (150) N'3 words' AS n, CONCAT(w1, N' ', w2, N' ', w3) AS words, COUNT(DISTINCT article_key) AS titles
FROM nxt WHERE w3 IS NOT NULL
GROUP BY CONCAT(w1, N' ', w2, N' ', w3)
ORDER BY titles DESC;

-- 3. Upper-case words of 2-5 letters (tickers, acronyms). BIN2 makes the [A-Z] test case-sensitive;
--    under the database collation [A-Z] would also match lower case.
--    in_bank_titles = titles that also contain "ngân hàng" or a word with "bank".
WITH bank_titles AS (
    SELECT DISTINCT article_key FROM #tok WHERE w LIKE N'%bank%'
    UNION
    SELECT t1.article_key
    FROM #tok t1 JOIN #tok t2 ON t2.article_key = t1.article_key AND t2.pos = t1.pos + 1
    WHERE t1.w = N'ngân' AND t2.w = N'hàng'
)
SELECT TOP (200)
       t.w COLLATE Latin1_General_BIN2 AS word,
       COUNT(DISTINCT t.article_key) AS titles,
       COUNT(DISTINCT b.article_key) AS in_bank_titles
FROM #tok t
LEFT JOIN bank_titles b ON b.article_key = t.article_key
WHERE LEN(t.w) BETWEEN 2 AND 5
  AND t.w COLLATE Latin1_General_BIN2 NOT LIKE N'%[^A-Z]%'
GROUP BY t.w COLLATE Latin1_General_BIN2
ORDER BY in_bank_titles DESC, titles DESC;
