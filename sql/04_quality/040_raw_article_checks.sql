USE BankingSectorIntelligence;

-- 1. Sitemap entries: rows, distinct URLs, URLs listed in more than one bucket file.
SELECT COUNT(*) AS rows_total,
       COUNT(DISTINCT [url]) AS distinct_urls,
       COUNT(*) - COUNT(DISTINCT [url]) AS extra_rows_from_repeated_urls
FROM raw.raw_article;

-- 2. Values that don't convert or are empty.
SELECT SUM(CASE WHEN TRY_CONVERT(datetimeoffset(0), [lastmod]) IS NULL THEN 1 ELSE 0 END) AS lastmod_bad,
       SUM(CASE WHEN RIGHT([lastmod], 6) <> N'+07:00' THEN 1 ELSE 0 END)                  AS lastmod_not_plus7,
       SUM(CASE WHEN [title] IS NULL OR [title] = N'' THEN 1 ELSE 0 END)                  AS title_empty,
       SUM(CASE WHEN [title] LIKE N'%CDATA%' OR [title] LIKE N'%&amp;%' THEN 1 ELSE 0 END) AS title_not_decoded
FROM raw.raw_article;

-- 3. Fetched pages: how many, how many have a publish time, how many can't be tied to a URL.
SELECT COUNT(*) AS pages,
       SUM(CASE WHEN [published_time] IS NULL THEN 1 ELSE 0 END) AS no_published_time,
       SUM(CASE WHEN TRY_CONVERT(datetime2(0), [published_time]) IS NULL
                 AND [published_time] IS NOT NULL THEN 1 ELSE 0 END) AS published_time_bad,
       SUM(CASE WHEN [url] IS NULL THEN 1 ELSE 0 END) AS no_url
FROM raw.raw_article_page;

-- 4. Every fetched page should belong to a sitemap URL.
SELECT p.[url], p.source_file
FROM raw.raw_article_page p
WHERE NOT EXISTS (SELECT 1 FROM raw.raw_article a WHERE a.[url] = p.[url]);

-- 5. Sitemap title vs page og:title, for the pages fetched so far.
SELECT SUM(CASE WHEN a.[title] = p.[og_title] THEN 1 ELSE 0 END)  AS same_title,
       SUM(CASE WHEN a.[title] <> p.[og_title] THEN 1 ELSE 0 END) AS different_title
FROM raw.raw_article_page p
JOIN (SELECT DISTINCT [url], [title] FROM raw.raw_article) a ON a.[url] = p.[url];

-- 6. URLs listed in more than one bucket file: do the title or lastmod differ between the rows?
SELECT COUNT(*)                                          AS repeated_urls,
       SUM(CASE WHEN n_titles > 1 THEN 1 ELSE 0 END)     AS with_different_titles,
       MIN(span_hours)                                   AS min_lastmod_span_hours,
       MAX(span_hours)                                   AS max_lastmod_span_hours
FROM (
    SELECT [url],
           COUNT(DISTINCT [title]) AS n_titles,
           DATEDIFF(minute, MIN(CAST([lastmod] AS datetimeoffset(0))), MAX(CAST([lastmod] AS datetimeoffset(0)))) / 60.0 AS span_hours
    FROM raw.raw_article
    GROUP BY [url]
    HAVING COUNT(*) > 1
) d;

-- 6b. The repeated URLs whose title differs, side by side.
SELECT a.[url], a.[lastmod], a.[title], a.source_file
FROM raw.raw_article a
WHERE a.[url] IN (SELECT [url] FROM raw.raw_article GROUP BY [url] HAVING COUNT(DISTINCT [title]) > 1)
ORDER BY a.[url], a.[lastmod];

-- 7. Unicode form. Vietnamese letters written as base letter + combining mark (U+0300 to U+036F)
--    are not in NFC. The binary collation makes LIKE compare code points, so the range works.
SELECT N'raw_article.title' AS col, COUNT(*) AS rows_with_combining_marks
FROM raw.raw_article
WHERE [title] COLLATE Latin1_General_BIN2 LIKE N'%[' + NCHAR(0x0300) + N'-' + NCHAR(0x036F) + N']%'
UNION ALL
SELECT N'raw_article_page.og_title', COUNT(*)
FROM raw.raw_article_page
WHERE [og_title] COLLATE Latin1_General_BIN2 LIKE N'%[' + NCHAR(0x0300) + N'-' + NCHAR(0x036F) + N']%'
UNION ALL
SELECT N'raw_ticker_news.title', COUNT(*)
FROM raw.raw_ticker_news
WHERE [title] COLLATE Latin1_General_BIN2 LIKE N'%[' + NCHAR(0x0300) + N'-' + NCHAR(0x036F) + N']%';

-- 7b. Does the database collation treat "Thường" (precomposed) and the same word written with
--     combining marks as equal, in = and in LIKE? Compared with a binary collation.
DECLARE @nfc NVARCHAR(20) = N'Thường';
DECLARE @nfd NVARCHAR(20) = N'Thu' + NCHAR(0x031B) + N'o' + NCHAR(0x031B) + NCHAR(0x0300) + N'ng';
SELECT LEN(@nfc) AS len_nfc,
       LEN(@nfd) AS len_nfd,
       CASE WHEN @nfc = @nfd COLLATE Vietnamese_100_CI_AS THEN 1 ELSE 0 END                               AS equal_vietnamese_ci_as,
       CASE WHEN N'Ngân hàng ' + @nfd + N' mại' LIKE N'%' + @nfc + N'%' COLLATE Vietnamese_100_CI_AS THEN 1 ELSE 0 END AS like_vietnamese_ci_as,
       CASE WHEN @nfc = @nfd COLLATE Latin1_General_BIN2 THEN 1 ELSE 0 END                                AS equal_bin2;

-- 8. Page publish time: format. article:published_time is local time without an offset.
SELECT LEN([published_time])                       AS len,
       SUBSTRING([published_time], 11, 1)          AS sep,
       COUNT(*)                                    AS pages,
       MIN([published_time])                       AS min_value,
       MAX([published_time])                       AS max_value
FROM raw.raw_article_page
WHERE [published_time] IS NOT NULL
GROUP BY LEN([published_time]), SUBSTRING([published_time], 11, 1);

-- 9. URL length and characters, to size the staging key. A clustered index key can hold at most
--    900 bytes; NVARCHAR uses 2 bytes per character, VARCHAR 1 for ASCII.
SELECT MAX(LEN([url]))                                                                  AS max_len,
       SUM(CASE WHEN [url] COLLATE Latin1_General_BIN2 LIKE N'%[^ -~]%' THEN 1 ELSE 0 END)   AS non_ascii,  -- outside printable ASCII
       SUM(CASE WHEN [url] LIKE N'% %' OR [url] LIKE N'%?%' OR [url] NOT LIKE N'https://cafef.vn/%' THEN 1 ELSE 0 END) AS odd_form
FROM raw.raw_article;

-- 10. Article ID = the digits between the last '-' and '.chn'. The per-ticker list showed that
--     CafeF can serve one article under two slugs, so the ID may be a better key than the URL.
--     Is every ID all digits, and does any ID sit under more than one URL in the sitemap?
WITH ids AS (
    SELECT a.[url], a.[lastmod],
           RIGHT(x.stem, NULLIF(CHARINDEX(N'-', REVERSE(x.stem)), 0) - 1) AS article_id
    FROM raw.raw_article a
    CROSS APPLY (SELECT CASE WHEN a.[url] LIKE N'%.chn' THEN LEFT(a.[url], LEN(a.[url]) - 4) END AS stem) x
)
SELECT COUNT(DISTINCT [url])                                                          AS distinct_urls,
       COUNT(DISTINCT article_id)                                                     AS distinct_ids,
       SUM(CASE WHEN article_id IS NULL OR article_id LIKE N'%[^0-9]%' THEN 1 ELSE 0 END) AS rows_bad_id,
       MIN(LEN(article_id))                                                           AS min_id_len,
       MAX(LEN(article_id))                                                           AS max_id_len
FROM ids;

-- 10b. IDs listed under more than one URL.
WITH ids AS (
    SELECT a.[url], a.[lastmod], a.[title],
           RIGHT(x.stem, NULLIF(CHARINDEX(N'-', REVERSE(x.stem)), 0) - 1) AS article_id
    FROM raw.raw_article a
    CROSS APPLY (SELECT CASE WHEN a.[url] LIKE N'%.chn' THEN LEFT(a.[url], LEN(a.[url]) - 4) END AS stem) x
)
SELECT i.article_id, i.[url], i.[lastmod], i.[title]
FROM ids i
WHERE i.article_id IN (SELECT article_id FROM ids GROUP BY article_id HAVING COUNT(DISTINCT [url]) > 1)
ORDER BY i.article_id, i.[lastmod];
