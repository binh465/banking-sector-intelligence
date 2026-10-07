-- Sitemap title vs og:title as the text the matching rules read.
--   1. Coverage: how many articles have an og:title, and how many differ from the sitemap title.
--   2. Alias terms found in one text and not the other, per article-bank pair. A screen without
--      exclusions or guards, not the full rules of 500.
--   3. Pairs found only in og:title (in-scope banks), for reading.
USE BankingSectorIntelligence;
GO

DECLARE @punct NVARCHAR(40) = N',.:;!?()"“”‘’[]…|/«»*+=#@';
DECLARE @space NVARCHAR(40) = REPLICATE(N' ', LEN(@punct));

-- 1. -----------------------------------------------------------------------------------------------
SELECT COUNT(*)                                                                    AS articles,
       SUM(CASE WHEN og_title IS NOT NULL THEN 1 ELSE 0 END)                       AS with_og_title,
       SUM(CASE WHEN og_title IS NOT NULL AND og_title <> title THEN 1 ELSE 0 END) AS og_differs
FROM dw.dim_article
WHERE item_type = 'article';

-- 1b. A few differences, to see what kind they are.
SELECT TOP (20) article_key, title, og_title
FROM dw.dim_article
WHERE item_type = 'article' AND og_title IS NOT NULL AND og_title <> title
ORDER BY article_key;

-- 2. -----------------------------------------------------------------------------------------------
IF OBJECT_ID(N'tempdb..#d') IS NOT NULL DROP TABLE #d;
SELECT article_key,
       CAST(N' ' + TRANSLATE(title,    @punct, @space) + N' ' AS NVARCHAR(1200)) COLLATE DATABASE_DEFAULT AS t_title,
       CAST(N' ' + TRANSLATE(og_title, @punct, @space) + N' ' AS NVARCHAR(1200)) COLLATE DATABASE_DEFAULT AS t_og
INTO #d
FROM dw.dim_article
WHERE item_type = 'article' AND og_title IS NOT NULL AND og_title <> title;

IF OBJECT_ID(N'tempdb..#hits') IS NOT NULL DROP TABLE #hits;
SELECT d.article_key, a.bank_id,
       MAX(CASE WHEN (a.case_sensitive = 0 AND d.t_title LIKE N'% ' + a.term + N' %')
                  OR (a.case_sensitive = 1 AND d.t_title COLLATE Latin1_General_BIN2
                                               LIKE (N'% ' + a.term + N' %') COLLATE Latin1_General_BIN2)
                THEN 1 ELSE 0 END) AS in_title,
       MAX(CASE WHEN (a.case_sensitive = 0 AND d.t_og LIKE N'% ' + a.term + N' %')
                  OR (a.case_sensitive = 1 AND d.t_og COLLATE Latin1_General_BIN2
                                               LIKE (N'% ' + a.term + N' %') COLLATE Latin1_General_BIN2)
                THEN 1 ELSE 0 END) AS in_og
INTO #hits
FROM #d d
CROSS JOIN stg.stg_alias a
GROUP BY d.article_key, a.bank_id;

SELECT b.in_scope,
       SUM(CASE WHEN h.in_title = 1 AND h.in_og = 1 THEN 1 ELSE 0 END) AS in_both,
       SUM(CASE WHEN h.in_title = 1 AND h.in_og = 0 THEN 1 ELSE 0 END) AS title_only,
       SUM(CASE WHEN h.in_title = 0 AND h.in_og = 1 THEN 1 ELSE 0 END) AS og_only
FROM #hits h
JOIN stg.stg_bank b ON b.bank_id = h.bank_id
GROUP BY b.in_scope
ORDER BY b.in_scope DESC;

-- 3. -----------------------------------------------------------------------------------------------
SELECT h.bank_id, a.article_key, a.title, a.og_title
FROM #hits h
JOIN stg.stg_bank b    ON b.bank_id = h.bank_id AND b.in_scope = 1
JOIN dw.dim_article a  ON a.article_key = h.article_key
WHERE h.in_og = 1 AND h.in_title = 0
ORDER BY h.bank_id, a.article_key;
GO