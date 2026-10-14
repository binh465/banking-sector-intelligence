-- dq.dq_run, dq.dq_check_result: data quality check history (decisions.md 2026-10-14).
-- History tables: rows are only added. This file creates the tables only when they are missing and
-- never drops them; a change of structure is an ALTER, not a drop and re-create.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'dq.dq_run', N'U') IS NULL
CREATE TABLE dq.dq_run (
	run_id				INT IDENTITY(1,1)	NOT NULL,
	started_at_utc		DATETIME2(0)		NOT NULL CONSTRAINT df_dq_run_started DEFAULT SYSUTCDATETIME(),
	finished_at_utc		DATETIME2(0)		NULL, -- NULL: the run stopped before the end
	run_by				SYSNAME				NOT NULL CONSTRAINT df_dq_run_by DEFAULT SYSTEM_USER,
	run_status			VARCHAR(10)			NOT NULL,
	CONSTRAINT pk_dq_run PRIMARY KEY (run_id),
	CONSTRAINT ck_dq_run_status CHECK (run_status IN ('running', 'completed', 'failed'))
);

IF OBJECT_ID(N'dq.dq_check_result', N'U') IS NULL
CREATE TABLE dq.dq_check_result (
	run_id				INT				NOT NULL,
	check_name			VARCHAR(100)	NOT NULL,
	layer				VARCHAR(10)		NOT NULL, -- raw / stg / dw / mart
	severity			VARCHAR(5)		NOT NULL, -- ERROR or WARN
	checked_count		INT				NULL, -- rows the check looked at
	failed_count		INT				NOT NULL,
	check_status	AS (
		CASE WHEN failed_count = 0 THEN 'PASS'
			ELSE severity
		END
	) PERSISTED,
	sample_keys			NVARCHAR(400)		NULL,
	description			NVARCHAR(400)		NOT NULL,
	checked_at_utc		DATETIME2(0)		NOT NULL CONSTRAINT df_dq_result_at DEFAULT SYSUTCDATETIME(),
	CONSTRAINT pk_dq_check_result		PRIMARY KEY (run_id, check_name),
	CONSTRAINT fk_dq_result_run			FOREIGN KEY (run_id) REFERENCES dq.dq_run (run_id),
	CONSTRAINT ck_dq_result_layer		CHECK (layer IN ('raw', 'stg', 'dw', 'mart')),
	CONSTRAINT ck_dq_result_severity	CHECK (severity	IN ('ERROR', 'WARN')),
	CONSTRAINT ck_dq_result_counts		CHECK (failed_count >= 0 AND (checked_count IS NULL OR failed_count <= checked_count))
);
GO