# Alias survey (Phase 5, step 1)

How CafeF titles name banks, measured on the 248,415 distinct sitemap titles (2024-09-21 to
2026-09-30, a few days wider than the window). First pass with `sql/04_quality/500_alias_discovery.sql`;
the full lists were read with a quick scan of the same titles in raw/news/sitemaps, because the SSMS
result grids only show a few rows at a time. Counts are titles with the phrase as a whole word.
The SQL matching in Phase 5 re-measures everything on dim_article.

Result: `config/aliases.yaml` (draft).

## 1. Brand names carry the matching

| Bank | Brand name | Titles | Ticker in title | Titles |
|---|---|---|---|---|
| VCB | Vietcombank | 819 | VCB | 24 |
| CTG | VietinBank | 662 | CTG | 9 |
| VPB | VPBank | 504 | VPB | 29 |
| TCB | Techcombank | 478 | TCB | 18 |
| STB | Sacombank | 468 | STB | 16 |
| HDB | HDBank | 302 | HDB | 20 |
| TPB | TPBank | 171 | TPB | 5 |
| MBB | MB (upper case) / MBBank / MB Bank | 486 / 35 / 28 | MBB | 17 |
| ACB | - | - | ACB | 422 |
| SHB | - | - | SHB | 242 |

- Tickers are rare in titles except where the ticker is the brand (ACB, SHB).
- Legal names ("Ngân hàng TMCP ...") almost never appear: Kỹ thương 1, Sài Gòn - Hà Nội 1,
  Phát triển Thành phố Hồ Chí Minh 1, Sài Gòn Thương Tín 0, Á Châu 0. Kept as strong aliases anyway.

## 2. Short Vietnamese names: mostly common words

Whole-word counts, then how many of those titles also contain "ngân hàng", "nhà băng" or "bank"
(context), then "ngân hàng/nhà băng" directly in front of the name (adjacent).

| Name | Titles | With context | Adjacent | What the titles are about |
|---|---|---|---|---|
| Tiên Phong | 394 | 50 | 2 | "tiên phong" = pioneering; both adjacent hits are "ngân hàng tiên phong" (a pioneering bank) |
| Tài Lộc | 558 | 7 | 0 | feng-shui word; context hits are about Sacombank's rename |
| Thịnh Vượng | 182 | 13 | 0 | "prosperity"; context hits already say VPBank |
| Quân đội | 294 | 27 | 26 | army; adjacent hits are MB ("Ngân hàng Quân đội (MB)") |
| Công Thương | 313 | 3 | 3 | Bộ Công Thương (ministry); one adjacent hit is China's ICBC |
| Ngoại thương | 46 | 3 | 3 | Foreign Trade University; adjacent hits are Vietcombank |
| Á Châu | 8 | 0 | 0 | other companies (AIG, Hòn Ngọc Á Châu) |
| MB (upper case) | 486 | 325 | 25 | context hits are mostly bank lists and MB itself |

- Consequence: "Ngân hàng + name" goes into the strong list where it is unambiguous (Quân đội,
  Ngoại thương, Kỹ thương); the bare short names are left out. Only "MB" stays as a weak alias.
- "Tiên Phong" is left out even with "Ngân hàng" in front: the phrase is an ordinary description.

## 3. Subsidiaries and look-alikes (exclusions)

| Phrase | Titles | Parent name inside |
|---|---|---|
| VPBankS | 130 | VPBank (whole-word rule already separates it) |
| TCBS | 106 | TCB (same) |
| MBS | 90 | MB (same) |
| FE Credit | 36 | - (VPBank's consumer finance arm) |
| ACBS | 24 | ACB (same) |
| MBV | 19 | MB (same); a separate bank since the takeover |
| VCBS | 14 | VCB (same) |
| Chứng khoán Tiên Phong / TPS | 11 / 14 | - |
| VietinBank Capital / Securities / Chứng khoán VietinBank | 10 / 7 / 7 | VietinBank (whole word, so the rule alone would match) |
| Chứng khoán MB | 9 | MB |
| Sacombank-SBR / SBJ | 7 / 3 | Sacombank (a hyphen counts as a word boundary) |
| VCBNeo | 6 | VCB (whole-word rule separates it) |
| HD Saison | 5 | - |
| MB Ageas | 4 | MB |
| Ngân hàng Nhà nước / NHNN | 363 / 274 | the regulator, not a bank |
| SoftBank | 25 | not a bank |

Phrases where the whole-word rule is not enough (a space or a hyphen after the bank name) must be
on the exclusion list; the others are listed too, so the intent is written down.

## 4. Banks outside the 10 (for banks_mentioned)

BIDV 689, Agribank 613, VIB 290, LPBank 181, MSB 144, Eximbank 142, OCB 111, BVBank 98, NCB 75,
Nam A Bank 64, ABBank 61, SCB 58, KienlongBank 57, Vietbank 50, UOB 49, SeABank 42, Shinhan 30,
Vikki 29, HSBC 26, VietABank 25, PGBank 25, GPBank 16, PVcomBank 14, Maybank 13, Saigonbank 12,
Bac A Bank 9, Standard Chartered 9, OceanBank 8, BaoViet Bank 6, Woori 5, Citibank 2.

## 5. Follow-up: "MB" without a context word (2026-10-02)

`510_match_checks.sql` query 8: 239 titles with "MB" not matched to MBB under the context rule
(150 naming no other bank, 89 naming another bank). 40 read by hand: 36 the bank, 1 file size
("8 MB"), MB Life, MB Capital, 1 already excluded. "MB" moved to the strong list (decisions.md).
