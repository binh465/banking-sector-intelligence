-- Timing of the statements in 520_precision_sample.sql, one step at a time.
-- Each step writes its rows into a #temp table instead of the grid, so the time is the server's,
-- not SSMS drawing results. Waits come from sys.dm_exec_session_wait_stats (this session only),
-- read before and after each step; the difference is what the step waited on (locks, memory grant,
-- disk, ...). Needs VIEW SERVER STATE; a local admin login has it.
-- Part A: run from the top down to the first GO. Result: one row per step.
-- Part B (end of file) is for a batch that is slow while it runs; see there.
USE BankingSectorIntelligence;
SET NOCOUNT ON;

DROP TABLE IF EXISTS #t, #w, #r1, #r2, #r3, #r4, #r5, #r6, #r7;
CREATE TABLE #t (step NVARCHAR(60) COLLATE DATABASE_DEFAULT, started DATETIME2(7), ended DATETIME2(7), rows_out INT);
CREATE TABLE #w (step NVARCHAR(60) COLLATE DATABASE_DEFAULT, phase CHAR(1),
                 wait_type NVARCHAR(60) COLLATE DATABASE_DEFAULT, wait_time_ms BIGINT);

DECLARE @s DATETIME2(7), @n INT;

-- Step 1: view, count only
INSERT #w SELECT N'1 view count', 'b', wait_type, wait_time_ms FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;
SET @s = SYSDATETIME();
SELECT COUNT(*) AS n INTO #r1 FROM stg.v_precision_sample;
SET @n = @@ROWCOUNT;
INSERT #t VALUES (N'1 view count', @s, SYSDATETIME(), @n);
INSERT #w SELECT N'1 view count', 'a', wait_type, wait_time_ms FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;

-- Step 2: view, every column (what the export script reads)
INSERT #w SELECT N'2 view all columns', 'b', wait_type, wait_time_ms FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;
SET @s = SYSDATETIME();
SELECT label_order, stratum, url, ticker, matched_term, title, publish_time_local, stratum_pairs
INTO #r2 FROM stg.v_precision_sample;
SET @n = @@ROWCOUNT;
INSERT #t VALUES (N'2 view all columns', @s, SYSDATETIME(), @n);
INSERT #w SELECT N'2 view all columns', 'a', wait_type, wait_time_ms FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;

-- Step 3: query 1 of 520
INSERT #w SELECT N'3 query 1', 'b', wait_type, wait_time_ms FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;
SET @s = SYSDATETIME();
SELECT stratum, COUNT(*) AS sampled, MAX(stratum_pairs) AS stratum_pairs
INTO #r3 FROM stg.v_precision_sample GROUP BY stratum;
SET @n = @@ROWCOUNT;
INSERT #t VALUES (N'3 query 1', @s, SYSDATETIME(), @n);
INSERT #w SELECT N'3 query 1', 'a', wait_type, wait_time_ms FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;

-- Step 4: query 2 of 520
INSERT #w SELECT N'4 query 2', 'b', wait_type, wait_time_ms FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;
SET @s = SYSDATETIME();
SELECT COUNT(*) AS pairs, CHECKSUM_AGG(CHECKSUM(url, ticker)) AS sample_fingerprint
INTO #r4 FROM stg.v_precision_sample;
SET @n = @@ROWCOUNT;
INSERT #t VALUES (N'4 query 2', @s, SYSDATETIME(), @n);
INSERT #w SELECT N'4 query 2', 'a', wait_type, wait_time_ms FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;

-- Step 5: query 3a of 520, first side (view EXCEPT file)
INSERT #w SELECT N'5 query 3a view-file', 'b', wait_type, wait_time_ms FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;
SET @s = SYSDATETIME();
SELECT url, ticker INTO #r5
FROM (SELECT url, ticker FROM stg.v_precision_sample
      EXCEPT
      SELECT url, ticker FROM raw.raw_precision_label) x;
SET @n = @@ROWCOUNT;
INSERT #t VALUES (N'5 query 3a view-file', @s, SYSDATETIME(), @n);
INSERT #w SELECT N'5 query 3a view-file', 'a', wait_type, wait_time_ms FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;

-- Step 6: query 3a of 520, second side (file EXCEPT view)
INSERT #w SELECT N'6 query 3a file-view', 'b', wait_type, wait_time_ms FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;
SET @s = SYSDATETIME();
SELECT url, ticker INTO #r6
FROM (SELECT url, ticker FROM raw.raw_precision_label
      EXCEPT
      SELECT url, ticker FROM stg.v_precision_sample) y;
SET @n = @@ROWCOUNT;
INSERT #t VALUES (N'6 query 3a file-view', @s, SYSDATETIME(), @n);
INSERT #w SELECT N'6 query 3a file-view', 'a', wait_type, wait_time_ms FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;

-- Step 7: query 3c of 520 (titles, where the file has one). 3b is a count on the 300-row file, not timed.
INSERT #w SELECT N'7 query 3c titles', 'b', wait_type, wait_time_ms FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;
SET @s = SYSDATETIME();
SELECT v.url, v.ticker INTO #r7
FROM stg.v_precision_sample v
JOIN raw.raw_precision_label f ON f.url = v.url AND f.ticker = v.ticker
WHERE f.title IS NOT NULL
  AND (v.title IS NULL OR f.title <> v.title);
SET @n = @@ROWCOUNT;
INSERT #t VALUES (N'7 query 3c titles', @s, SYSDATETIME(), @n);
INSERT #w SELECT N'7 query 3c titles', 'a', wait_type, wait_time_ms FROM sys.dm_exec_session_wait_stats WHERE session_id = @@SPID;

-- Result: elapsed time per step and the waits that grew during it (ms, largest first).
SELECT t.step,
       DATEDIFF(millisecond, t.started, t.ended) AS elapsed_ms,
       t.rows_out,
       (SELECT STRING_AGG(CONCAT(a.wait_type, N' ', a.wait_time_ms - ISNULL(b.wait_time_ms, 0)), N', ')
                   WITHIN GROUP (ORDER BY a.wait_time_ms - ISNULL(b.wait_time_ms, 0) DESC)
        FROM #w a
        LEFT JOIN #w b ON b.step = a.step AND b.phase = 'b' AND b.wait_type = a.wait_type
        WHERE a.step = t.step AND a.phase = 'a'
          AND a.wait_time_ms - ISNULL(b.wait_time_ms, 0) > 0) AS waits_ms
FROM #t t
ORDER BY t.step;
GO

-- Part B: what a slow batch is waiting on. Not part of the F5 run above: while the slow batch is
-- running in its own tab, select from here to the end in a second tab and run it (F5 on a selection).
-- First result: requests in this database that are running now, with their wait and blocker.
-- Second result: the sessions that block them, and the last statement each one sent.
SELECT r.session_id, r.status, r.command, r.wait_type, r.wait_time AS wait_ms,
       r.blocking_session_id, r.wait_resource, st.text AS running_sql
FROM sys.dm_exec_requests r
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) st
WHERE r.database_id = DB_ID(N'BankingSectorIntelligence')
  AND r.session_id <> @@SPID;

SELECT s.session_id, s.program_name, s.status, s.open_transaction_count,
       s.last_request_end_time, st.text AS last_sql
FROM sys.dm_exec_sessions s
LEFT JOIN sys.dm_exec_connections c ON c.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) st
WHERE s.session_id IN (SELECT blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0);
