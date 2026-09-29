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
