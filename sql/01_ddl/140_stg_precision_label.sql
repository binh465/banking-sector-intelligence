-- stg.stg_precision_label: the hand-labelled precision sample, typed and checked.
-- One row per sampled item-bank pair, keyed by the natural keys (url, ticker), so the labels survive a
-- rebuild of dw. Loaded from raw.raw_precision_label by sql/02_load/130_load_stg_precision_label.sql.
--   stratum_pairs  stratum size when the sample was drawn (weights for the overall figures)
--   case_code      the labelling case from the note (A-H, C1-C3), NULL when the row has no note
-- Creates the table only if it doesn't exist.
USE BankingSectorIntelligence;
GO

IF OBJECT_ID(N'stg.stg_precision_label', N'U') IS NULL
CREATE TABLE stg.stg_precision_label (
    url              VARCHAR(400)    NOT NULL,
    ticker           NVARCHAR(10)    NOT NULL,
    label_order      SMALLINT        NOT NULL,
    stratum          VARCHAR(20)     NOT NULL,
    stratum_pairs    INT             NOT NULL,
    matched_term     NVARCHAR(200)   NULL,
    is_correct       BIT             NOT NULL,
    is_main_subject  BIT             NOT NULL,
    case_code        VARCHAR(5)      NULL,
    note             NVARCHAR(1000)  NULL,
    loaded_at_utc    DATETIME2(0)    NOT NULL CONSTRAINT df_stg_precision_label_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_stg_precision_label PRIMARY KEY (url, ticker),
    CONSTRAINT uq_stg_precision_label_order UNIQUE (label_order),
    CONSTRAINT ck_stg_precision_label_stratum CHECK (stratum IN ('t0_disclosure', 't1_ticker', 't2_other', 't2_mb')),
    CONSTRAINT ck_stg_precision_label_main CHECK (is_correct = 1 OR is_main_subject = 0)
);
GO
