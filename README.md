# Banking Sector Intelligence

A SQL-first data warehouse on 10 HOSE-listed Vietnamese banks
(VCB, CTG, TCB, MBB, ACB, VPB, STB, HDB, TPB, SHB).

Central question: which of these tickers is diverging from the sector,
since when, and what news appeared around that time.

> This is a data analysis project, not an investment recommendation tool.
> Nothing here is advice to buy or sell any security.

## Stack
- SQL Server 2025 Express (all transformation, modelling, analytics, data quality)
- Python 3.12 (conda env `bsi`) - Phase 1 ingestion only
- Power BI Desktop

## Layout
```
config/   scope, tickers, db connection template
ingest/   Python download + load scripts (Phase 1)
raw/      raw snapshots (prices, calendar committed; news git-ignored)
sql/      01_ddl, 02_load, 03_transform, 04_quality
powerbi/  report files
docs/     decisions, test results, data dictionary
```

## Naming
`raw_`, `stg_`, `dim_`, `fact_`, `v_` (view), `sp_` (procedure).
Schemas: `raw`, `stg`, `dw`, `mart`.

_Work in progress._
