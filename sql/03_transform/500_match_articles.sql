-- Match CafeF article titles (dw.dim_article, item_type = 'article') to banks with the alias rules
-- (stg.stg_alias, stg.stg_alias_context, stg.stg_alias_exclusion). Writes stg.stg_article_bank_match.
-- Disclosures are not matched here: their bank comes from the per-ticker list (match_tier 0).
--
-- Whole-word matching without regex:
--   1. punctuation in the title becomes a space, and the title gets a space at both ends;
--   2. a term matches when ' ' + term + ' ' is inside that text.
--   So "VPBankS", "TCBS", "VCBNeo" never match VPBank / TCB / VCB. A hyphen is not punctuation here,
--   so "Sacombank-SBR" does not match Sacombank either.
-- Case-sensitive terms (tickers, MB, BIDV, ...) are compared under a binary collation; the rest under
-- the database collation (case-insensitive, accent-sensitive).
-- A case-sensitive term right after a number is read as a unit, not a bank ("8 MB"), and dropped.
-- A number here is a digit not glued to a letter: "128 MB" is a unit, "BIG5 MB" is not.
-- The rule drops the whole title for that term, also when the term appears again elsewhere in it.
-- Exclusions are cut out of the text first, so a subsidiary or the regulator never counts as a bank
-- and "ngân hàng" inside "Ngân hàng Nhà nước" is not a context word.
USE BankingSectorIntelligence;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- Terms are put into LIKE patterns: a %, _ or [ inside a term would act as a wildcard.
IF EXISTS (SELECT 1 FROM stg.stg_alias WHERE term LIKE N'%[%_[]%')
   OR EXISTS (SELECT 1 FROM stg.stg_alias_exclusion WHERE term LIKE N'%[%_[]%' OR when_title_contains LIKE N'%[%_[]%')
   OR EXISTS (SELECT 1 FROM stg.stg_alias_context WHERE term LIKE N'%[%_[]%')
    THROW 50080, N'An alias, exclusion or context term contains %, _ or [', 1;

DECLARE @punct NVARCHAR(40) = N',.:;!?()"“”‘’[]…|/«»*+=#@';
DECLARE @space NVARCHAR(40) = REPLICATE(N' ', LEN(@punct));

-- 1. Title text with spaces at both ends.
IF OBJECT_ID(N'tempdb..#t') IS NOT NULL DROP TABLE #t;
CREATE TABLE #t (
    article_key INT NOT NULL PRIMARY KEY,
    txt         NVARCHAR(1200) COLLATE DATABASE_DEFAULT NOT NULL
);
INSERT INTO #t (article_key, txt)
SELECT article_key, N' ' + TRANSLATE(title, @punct, @space) + N' '
FROM dw.dim_article
WHERE item_type = 'article';

-- 2. Cut exclusions out. A loop over the exclusion rows, each step one set-based UPDATE.
--    REPLACE doesn't overlap matches (" MBS MBS " keeps the second), so each phrase repeats until gone.
--    An exclusion with when_title_contains is cut only from titles that contain that phrase
--    (database collation: case-insensitive, accent-sensitive).
DECLARE @term NVARCHAR(200), @cs BIT, @when NVARCHAR(200), @n INT;
DECLARE ex CURSOR LOCAL FAST_FORWARD FOR SELECT term, case_sensitive, when_title_contains FROM stg.stg_alias_exclusion;
OPEN ex;
FETCH NEXT FROM ex INTO @term, @cs, @when;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @n = 1;
    WHILE @n > 0
    BEGIN
        IF @cs = 1
            UPDATE #t SET txt = REPLACE(txt COLLATE Latin1_General_BIN2, N' ' + @term + N' ', N'  ')
            WHERE txt COLLATE Latin1_General_BIN2 LIKE N'% ' + @term + N' %'
              AND (@when IS NULL OR txt LIKE N'%' + @when + N'%');
        ELSE
            UPDATE #t SET txt = REPLACE(txt, N' ' + @term + N' ', N'  ')
            WHERE txt LIKE N'% ' + @term + N' %'
              AND (@when IS NULL OR txt LIKE N'%' + @when + N'%');
        SET @n = @@ROWCOUNT;
    END;
    FETCH NEXT FROM ex INTO @term, @cs, @when;
END;
CLOSE ex;
DEALLOCATE ex;

-- 3. Titles with a context word (after exclusions).
IF OBJECT_ID(N'tempdb..#ctx') IS NOT NULL DROP TABLE #ctx;
SELECT DISTINCT t.article_key
INTO #ctx
FROM #t t
JOIN stg.stg_alias_context c ON t.txt LIKE N'% ' + c.term + N' %';

-- 4. Every (title, term) hit, then one row per article per bank.
BEGIN TRANSACTION;

TRUNCATE TABLE stg.stg_article_bank_match;

WITH hits AS (
    SELECT t.article_key, a.bank_id, a.tier, a.term
    FROM #t t
    JOIN stg.stg_alias a
      ON (a.case_sensitive = 0 AND t.txt LIKE N'% ' + a.term + N' %')
      OR (a.case_sensitive = 1 AND t.txt COLLATE Latin1_General_BIN2 LIKE (N'% ' + a.term + N' %') COLLATE Latin1_General_BIN2)
    WHERE (a.tier < 3 OR EXISTS (SELECT 1 FROM #ctx c WHERE c.article_key = t.article_key))
      AND NOT (a.case_sensitive = 1
               AND t.txt COLLATE Latin1_General_BIN2 LIKE (N'%[^A-Za-z][0-9] ' + a.term + N' %') COLLATE Latin1_General_BIN2)
),
ranked AS (
    SELECT article_key, bank_id, tier, term,
           ROW_NUMBER() OVER (PARTITION BY article_key, bank_id ORDER BY tier, term) AS rn,
           COUNT(*)     OVER (PARTITION BY article_key, bank_id)                    AS terms_matched
    FROM hits
)
INSERT INTO stg.stg_article_bank_match (article_key, bank_id, best_tier, matched_term, terms_matched)
SELECT article_key, bank_id, tier, term, terms_matched
FROM ranked
WHERE rn = 1;

COMMIT TRANSACTION;

-- Summary: pairs and articles per scope and tier.
SELECT b.in_scope, m.best_tier, COUNT(*) AS article_bank_pairs, COUNT(DISTINCT m.article_key) AS articles
FROM stg.stg_article_bank_match m
JOIN stg.stg_bank b ON b.bank_id = m.bank_id
GROUP BY b.in_scope, m.best_tier
ORDER BY b.in_scope DESC, m.best_tier;
GO
