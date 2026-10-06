USE BankingSectorIntelligence
GO
DROP TABLE IF EXISTS #precision_stratum;
WITH counts AS (
	SELECT stratum,
		COUNT(*)																AS n,
		SUM(CASE WHEN is_correct = 1 THEN 1 ELSE 0 END)							AS k_match,
		SUM(CASE WHEN is_correct = 1 AND is_main_subject = 1 THEN 1 ELSE 0 END) AS k_usable,
		MAX(stratum_pairs)														AS stratum_pairs
	FROM stg.stg_precision_label
	GROUP BY stratum
), props AS (
	SELECT stratum,
		n,
		stratum_pairs,
		k_match,
		k_usable,
		k_match * 1.0 / NULLIF(n, 0) AS p_match,
		k_usable * 1.0 / NULLIF(n, 0) AS p_usable
	FROM counts
), wilson AS (
        SELECT stratum,
        n,
        stratum_pairs,
        k_match,
        p_match,
        k_usable,
        p_usable,

        -- Wilson interval parameters
        (1.96 * 1.96) / NULLIF(n, 0) AS z2_over_n,

        -- Match precision
        (p_match + (1.96 * 1.96) / (2.0 * NULLIF(n, 0))) / (1.0 + (1.96 * 1.96) / NULLIF(n, 0)) AS match_center,

        (1.96 * SQRT((p_match * (1.0 - p_match) / NULLIF(n, 0)) + ((1.96 * 1.96) / (4.0 * NULLIF(n, 0) * NULLIF(n, 0))))) /
        (1.0 + (1.96 * 1.96) / NULLIF(n, 0)) AS match_half,

        -- Usable precision
        (p_usable + (1.96 * 1.96) / (2.0 * NULLIF(n, 0))) / (1.0 + (1.96 * 1.96) / NULLIF(n, 0)) AS usable_center,

        (1.96 * SQRT((p_usable * (1.0 - p_usable)/ NULLIF(n, 0)) + ((1.96 * 1.96) / (4.0 * NULLIF(n, 0) * NULLIF(n, 0))))) /
        (1.0 + (1.96 * 1.96) / NULLIF(n, 0)) AS usable_half

    FROM props
)
SELECT
    stratum,
    n,
    stratum_pairs,

    k_match,
    p_match,
    match_center - match_half AS match_ci_lower,
    match_center + match_half AS match_ci_upper,

    k_usable,
    p_usable,
    usable_center - usable_half AS usable_ci_lower,
    usable_center + usable_half AS usable_ci_upper

INTO #precision_stratum

FROM wilson;

SELECT
    stratum,
    n,
    stratum_pairs,

    k_match,
    ROUND(p_match, 4) AS p_match,
    ROUND(match_ci_lower, 4) AS match_ci_lower,
    ROUND(match_ci_upper, 4) AS match_ci_upper,

    k_usable,
    ROUND(p_usable, 4) AS p_usable,
    ROUND(usable_ci_lower, 4) AS usable_ci_lower,
    ROUND(usable_ci_upper, 4) AS usable_ci_upper

FROM #precision_stratum
ORDER BY
    CASE stratum
        WHEN N't0_disclosure' THEN 1
        WHEN N't1_ticker' THEN 2
        WHEN N't2_mb' THEN 3
        WHEN N't2_other' THEN 4
        ELSE 99
    END;

SELECT N'all' AS scope,
    SUM(stratum_pairs * p_match) / NULLIF(SUM(stratum_pairs), 0) AS p_match_weighted,
    SUM(stratum_pairs * p_usable) / NULLIF(SUM(stratum_pairs), 0) AS p_usable_weighted
FROM #precision_stratum

UNION ALL

SELECT N'articles' AS scope,
    SUM(CASE WHEN stratum <> N't0_disclosure' THEN stratum_pairs * p_match END) 
       / NULLIF(SUM(CASE WHEN stratum <> N't0_disclosure' THEN stratum_pairs END), 0) AS p_match_weighted,
    SUM(CASE WHEN stratum <> N't0_disclosure' THEN stratum_pairs * p_usable END)
       / NULLIF(SUM(CASE WHEN stratum <> N't0_disclosure' THEN stratum_pairs END), 0) AS p_usable_weighted
FROM #precision_stratum