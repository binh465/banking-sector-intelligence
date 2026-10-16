-- Phase 9 measurement (decisions.md 2026-10-15). Run in ONE query window, in this order:
--   A once; B with @config = 'baseline'; apply I1 (910), B with 'I1', revert I1;
--   create I2 (910), B with 'I2', drop I2; C at the end. #perf lives as long as the window.
--   Run the last query of 910 after every index change and before B.
-- Before B: Query > Query Options > Results > Grid > "Discard results after execution", so drawing
-- result grids does not count. Warm cache: no DBCC DROPCLEANBUFFERS.
-- Each statement runs 6 times; run 1 warms up and is not used.
-- Times come from SYSDATETIME around the statement; CPU and logical reads from this request's
-- counters in sys.dm_exec_requests (own session, no extra permission), taken before and after.
-- Q1 and Q2 read every output column through CHECKSUM(*), so no column can be left uncomputed.
-- Q3 and the load run inside a transaction rolled back after the measurement: no dq history rows,
-- fact_news unchanged.
USE BankingSectorIntelligence;
GO

---------------------------------------------------------------------------- A. result table
IF OBJECT_ID(N'tempdb..#perf') IS NULL
    CREATE TABLE #perf (
        config      VARCHAR(20)  NOT NULL,
        query_name  VARCHAR(30)  NOT NULL,
        run_no      INT          NOT NULL,
        elapsed_ms  DECIMAL(12,3) NOT NULL,
        cpu_ms      INT          NOT NULL,
        logical_reads BIGINT     NOT NULL,
        PRIMARY KEY (config, query_name, run_no)
    );
GO

---------------------------------------------------------------------------- B. one configuration
DECLARE @config VARCHAR(20) = 'I2';   -- 'baseline', 'I1', 'I2'

IF EXISTS (SELECT 1 FROM #perf WHERE config = @config)
    THROW 50900, N'#perf already holds this configuration; delete its rows first', 1;

DECLARE @i INT, @t0 DATETIME2(7), @c0 INT, @r0 BIGINT, @chk INT;

-- Q1: window functions over fact_price_daily
SET @i = 1;
WHILE @i <= 6
BEGIN
    SELECT @c0 = cpu_time, @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    SET @t0 = SYSDATETIME();
    SELECT @chk = CHECKSUM_AGG(CHECKSUM(*)) FROM mart.v_excess_zscore;
    INSERT INTO #perf
    SELECT @config, 'Q1_v_excess_zscore', @i,
           DATEDIFF_BIG(MICROSECOND, @t0, SYSDATETIME()) / 1000.0,
           r.cpu_time - @c0, r.logical_reads - @r0
    FROM sys.dm_exec_requests r WHERE r.session_id = @@SPID;
    SET @i += 1;
END;

-- Q2: news joined to episodes
SET @i = 1;
WHILE @i <= 6
BEGIN
    SELECT @c0 = cpu_time, @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    SET @t0 = SYSDATETIME();
    SELECT @chk = CHECKSUM_AGG(CHECKSUM(*)) FROM mart.v_episode_news;
    INSERT INTO #perf
    SELECT @config, 'Q2_v_episode_news', @i,
           DATEDIFF_BIG(MICROSECOND, @t0, SYSDATETIME()) / 1000.0,
           r.cpu_time - @c0, r.logical_reads - @r0
    FROM sys.dm_exec_requests r WHERE r.session_id = @@SPID;
    SET @i += 1;
END;

-- Q3 and the load run inside a transaction that is rolled back. A table variable is not undone by a
-- rollback (a temp table insert is), so each measurement goes to @m first and reaches #perf after.
DECLARE @m TABLE (elapsed_ms DECIMAL(12,3), cpu_ms INT, logical_reads BIGINT);

-- Q3: the data quality checks (rolled back, so no history rows)
SET @i = 1;
WHILE @i <= 6
BEGIN
    DELETE FROM @m;
    BEGIN TRANSACTION;
    SELECT @c0 = cpu_time, @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    SET @t0 = SYSDATETIME();
    EXEC dq.sp_run_checks;
    INSERT INTO @m
    SELECT DATEDIFF_BIG(MICROSECOND, @t0, SYSDATETIME()) / 1000.0, r.cpu_time - @c0, r.logical_reads - @r0
    FROM sys.dm_exec_requests r WHERE r.session_id = @@SPID;
    ROLLBACK TRANSACTION;
    INSERT INTO #perf SELECT @config, 'Q3_sp_run_checks', @i, elapsed_ms, cpu_ms, logical_reads FROM @m;
    SET @i += 1;
END;

-- write cost: the fact_news load (rolled back, fact_news unchanged)
SET @i = 1;
WHILE @i <= 6
BEGIN
    DELETE FROM @m;
    BEGIN TRANSACTION;
    SELECT @c0 = cpu_time, @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    SET @t0 = SYSDATETIME();
    EXEC dw.sp_load_fact_news;
    INSERT INTO @m
    SELECT DATEDIFF_BIG(MICROSECOND, @t0, SYSDATETIME()) / 1000.0, r.cpu_time - @c0, r.logical_reads - @r0
    FROM sys.dm_exec_requests r WHERE r.session_id = @@SPID;
    ROLLBACK TRANSACTION;
    INSERT INTO #perf SELECT @config, 'L_sp_load_fact_news', @i, elapsed_ms, cpu_ms, logical_reads FROM @m;
    SET @i += 1;
END;

SELECT config, query_name, COUNT(*) AS runs FROM #perf WHERE config = @config GROUP BY config, query_name;
GO

---------------------------------------------------------------------------- C. summary
-- Median, min and max of runs 2-6 per configuration and statement; logical reads should not vary.
SELECT DISTINCT config, query_name,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY elapsed_ms) OVER (PARTITION BY config, query_name) AS median_elapsed_ms,
       MIN(elapsed_ms) OVER (PARTITION BY config, query_name) AS min_elapsed_ms,
       MAX(elapsed_ms) OVER (PARTITION BY config, query_name) AS max_elapsed_ms,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cpu_ms) OVER (PARTITION BY config, query_name) AS median_cpu_ms,
       MIN(logical_reads) OVER (PARTITION BY config, query_name) AS min_reads,
       MAX(logical_reads) OVER (PARTITION BY config, query_name) AS max_reads
FROM #perf
WHERE run_no > 1
ORDER BY query_name, config;
GO
