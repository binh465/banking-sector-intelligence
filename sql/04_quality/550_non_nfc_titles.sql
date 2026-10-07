-- Re-test of the article titles that are not in Unicode NFC (decomposed Vietnamese letters).
-- decisions.md, "No NFC normalisation": the database collation compares NFC and decomposed text as
-- equal; the binary collation used for case-sensitive terms in 500_match_articles.sql does not.
--   1. Case-sensitive terms (alias or exclusion) with a non-ASCII letter: only these could miss a
--      decomposed title.
--   2. The same LIKE pattern as 500, on a decomposed copy of a real alias.
--   3. The non-NFC article titles and the banks they matched, for reading.
USE BankingSectorIntelligence;
GO

DECLARE @marks NVARCHAR(20) = N'%[' + NCHAR(0x0300) + N'-' + NCHAR(0x036F) + N']%'; -- combining marks

-- 1. ---------------------------------------------------------------------------------------------
SELECT N'alias' AS king, bank_id, term
FROM stg.stg_alias
WHERE case_sensitive = 1
	AND term COLLATE Latin1_General_BIN2 LIKE N'%[^ -~]%'  -- any character outside printable ASCII
UNION ALL
SELECT N'exclusion', NULL, term
FROM stg.stg_alias_exclusion
WHERE case_sensitive = 1
	AND term COLLATE Latin1_General_BIN2 LIKE N'%[^ -~]%'


-- 2. ---------------------------------------------------------------------------------------------
-- "Ngân hàng Quân đội" with â and à written as base letter + combining mark (U+0302, U+0300).
DECLARE @nfd NVARCHAR(100) = N'Nga' + NCHAR(0x0302) + N'n ha' + NCHAR(0x0300) + N'ng Qua' + NCHAR(0x0302) + N'n đội';
SELECT LEN(@nfd)																	AS len_decomposed,
		LEN(N'Ngân hàng Quân đội')													AS len_nfc,
		CASE WHEN N' ' + @nfd + N' tăng lãi suất ' LIKE N'% Ngân hàng Quân đội %'
			THEN 1 ELSE 0 END														AS like_database_collation,
		CASE WHEN (N' ' + @nfd + N' tăng lãi suất ') COLLATE Latin1_General_BIN2
				LIKE N'% Ngân hàng Quân đội %' COLLATE Latin1_General_BIN2
			THEN 1 ELSE 0 END														AS like_bin2;

-- 3. ---------------------------------------------------------------------------------------------
SELECT a.article_key, a.publish_time_local, a.title,
       (SELECT STRING_AGG(m.bank_id, ', ') WITHIN GROUP (ORDER BY m.bank_id)
        FROM stg.stg_article_bank_match m
        WHERE m.article_key = a.article_key) AS banks_matched
FROM dw.dim_article a
WHERE a.item_type = 'article'
  AND a.title COLLATE Latin1_General_BIN2 LIKE @marks
ORDER BY a.publish_time_local;
GO