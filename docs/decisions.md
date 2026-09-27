# Decision log

One entry per decision: what, why, date. Newest at the bottom.

## 2026-09-27 - Analysis window
- Window is `(end_date - 2 years, end_date]`, stored in `config/scope.yaml`, never changed after lock.
- `end_date` = last completed HOSE session at lock time.
- `base_date` = first trading session on or after `start_date`, taken from the VNINDEX calendar, not guessed.
- Why: VCI adjusts prices retroactively, so a fixed window plus a committed raw snapshot is the only way to reproduce numbers.

## 2026-09-27 - Database collation
- `Vietnamese_100_CI_AS`; all text columns `NVARCHAR`.
- Why: news-to-ticker matching (Phase 5) compares Vietnamese bank names. Case-insensitive helps ticker matching; accent-insensitive would treat distinct syllables as equal and increase false matches.
- Known side effect: `#temp` tables take the server (tempdb) collation. Server collation is `Latin1_General_CI_AS` (checked 2026-09-27), so every `#temp` text column must declare `COLLATE DATABASE_DEFAULT`. Table variables are not affected.
- Setup note: the database first existed with the server default collation, and the create script skipped it silently. The script now THROWs on a collation mismatch; the database was dropped and rebuilt (verified: `Vietnamese_100_CI_AS`, `SIMPLE`, 4 schemas).

## 2026-09-27 - STB name change inside the window
- Ngân hàng TMCP Sài Gòn Thương Tín became Ngân hàng TMCP Sài Gòn Tài Lộc, effective 2026-06-01
  (SBV Decision 36/QĐ-QLGS4 dated 2026-06-01; approved by the AGM on 2026-04-22). Ticker STB and short name SACOMBANK unchanged.
- Source: https://www.sacombank.com.vn/trang-chu/tin-tuc/thong-bao/2026/sacombank-thong-bao-thay-doi-ten-goi.html
- Consequence: dim_ticker SCD Type 2 has one real change to model (STB gets two rows). Phase 3 still needs to
  confirm no other ticker changed its name in the window.
- Consequence for Phase 5: both names must be in the alias table; news before 2026-06-01 uses the old name.
