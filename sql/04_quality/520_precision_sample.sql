-- Precision sample for the item-bank pairs in dw.fact_news (decisions.md, 2026-10-03).
-- stg.v_precision_sample draws a fixed stratified sample:
--   t0_disclosure  match_tier 0, disclosure from the bank's own list      50 pairs
--   t1_ticker      match_tier 1, ticker in the title                       75 pairs
--   t2_other       match_tier 2, strong alias other than "MB"             100 pairs
--   t2_mb          match_tier 2 through "MB" alone                         75 pairs
--                  (a title with "MB" and "MBBank" does not rest on "MB": it goes to t2_other)
-- Tier 3 has no alias entry today; such rows would get stratum t3_weak and are not sampled.
--
-- Rows are ranked by a SHA-256 hash of a fixed salt + url + ticker, so the same population always
-- gives the same sample (NEWID() would give a new sample on every run). The hash uses the natural
-- keys, not article_key / ticker_key, so a rebuilt dw gives the same sample too.
-- label_order mixes the strata (a second hash) so labelling fatigue is spread over all of them.
-- stratum_pairs is the stratum size when sampled; the report weights strata by it.
--
-- ingest/export_precision_sample.py writes this view to docs/precision_sample.csv once. The CSV is
-- the frozen sample: labels are made there, not here.
USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW stg.v_precision_sample
AS
WITH pairs AS (
    SELECT a.url, t.ticker, f.match_tier, m.matched_term, a.title, a.publish_time_local,
           CASE WHEN f.match_tier = 0 THEN 't0_disclosure'
                WHEN f.match_tier = 1 THEN 't1_ticker'
                WHEN f.match_tier = 2 AND m.matched_term COLLATE Latin1_General_BIN2 = N'MB'
                     AND m.terms_matched = 1 THEN 't2_mb'
                WHEN f.match_tier = 2 THEN 't2_other'
                ELSE 't3_weak' END AS stratum
    FROM dw.fact_news f
    JOIN dw.dim_article a ON a.article_key = f.article_key
    JOIN dw.dim_ticker  t ON t.ticker_key  = f.ticker_key
    LEFT JOIN stg.stg_article_bank_match m          -- no row for disclosures (tier 0)
           ON m.article_key = f.article_key AND m.bank_id = t.ticker
),
ranked AS (
    SELECT p.*,
           ROW_NUMBER() OVER (PARTITION BY p.stratum
                              ORDER BY HASHBYTES('SHA2_256', CONCAT(N'bsi-precision-v1|', p.url, N'|', p.ticker)),
                                       p.url, p.ticker) AS sample_rank,
           COUNT(*) OVER (PARTITION BY p.stratum) AS stratum_pairs
    FROM pairs p
),
sampled AS (
    SELECT r.*
    FROM ranked r
    JOIN (VALUES ('t0_disclosure', 50), ('t1_ticker', 75), ('t2_other', 100), ('t2_mb', 75))
         AS s (stratum, sample_size) ON s.stratum = r.stratum
    WHERE r.sample_rank <= s.sample_size
)
SELECT ROW_NUMBER() OVER (ORDER BY HASHBYTES('SHA2_256', CONCAT(N'bsi-label-order-v1|', url, N'|', ticker)),
                                   url, ticker) AS label_order,
       stratum, url, ticker, ISNULL(matched_term, N'') AS matched_term, title, publish_time_local,
       stratum_pairs
FROM sampled;
GO

-- 1. Sample per stratum: pairs drawn, stratum size.
SELECT stratum, COUNT(*) AS sampled, MAX(stratum_pairs) AS stratum_pairs
FROM stg.v_precision_sample
GROUP BY stratum
ORDER BY stratum;

-- 2. Fingerprint of the sample. Recorded in pipeline_log when the CSV is exported; the same value on a
--    later day (or after a dw rebuild) means the same pairs were drawn.
SELECT COUNT(*) AS pairs, CHECKSUM_AGG(CHECKSUM(url, ticker)) AS sample_fingerprint
FROM stg.v_precision_sample;
GO

-- 3. After ingest/load_precision_labels.py: the file still holds the sampled pairs, and the titles it
--    holds are unchanged (Excel did not damage the text). The public CSV keeps the title column but
--    leaves it empty, so pairs are compared on (url, ticker) and titles only where the file has one.
IF OBJECT_ID(N'raw.raw_precision_label', N'U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM raw.raw_precision_label)
BEGIN
    -- 3a. Pairs, both ways.
    SELECT N'in view, not in file' AS side, url, ticker
    FROM (SELECT url, ticker FROM stg.v_precision_sample
          EXCEPT
          SELECT url, ticker FROM raw.raw_precision_label) x
    UNION ALL
    SELECT N'in file, not in view', url, ticker
    FROM (SELECT url, ticker FROM raw.raw_precision_label
          EXCEPT
          SELECT url, ticker FROM stg.v_precision_sample) y;

    -- 3b. File rows that carry a title. When this is 0, 3c has nothing to compare.
    SELECT COUNT(*) AS file_rows, COUNT(title) AS file_rows_with_title
    FROM raw.raw_precision_label;

    -- 3c. Titles that differ, for pairs whose file row has a title.
    SELECT v.url, v.ticker, v.title AS view_title, f.title AS file_title
    FROM stg.v_precision_sample v
    JOIN raw.raw_precision_label f ON f.url = v.url AND f.ticker = v.ticker
    WHERE f.title IS NOT NULL
      AND (v.title IS NULL OR f.title <> v.title);
END;
GO
