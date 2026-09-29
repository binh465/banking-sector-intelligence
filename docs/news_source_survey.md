# CafeF news source survey

Checked on 2026-09-27, before writing the crawler. All numbers were measured on the live site that day.

## robots.txt

```
User-agent: *
Allow: /
Sitemap: https://cafef.vn/sitemap.xml
Sitemap: https://cafef.vn/google-news-sitemap.xml
```

Nothing is disallowed. The crawler will use a real User-Agent, a short delay, and public pages only.

## Sitemap index (`https://cafef.vn/sitemap.xml`)

- 777 child sitemaps. Apart from `category.rss`, `google-news-sitemap.xml` and
  `latest-news-sitemap.xml`, they are archive files in 5-day buckets:
  `https://cafef.vn/sitemaps/sitemaps-{year}-{month}-{d1}-{d2}.xml`
  (1-5, 6-10, 11-15, 16-20, 21-25, 26-end of month), back to 2016.
- The window (2024-09-26 to 2026-09-25) covers about 146 buckets.

## One bucket in detail (`sitemaps-2026-9-21-25.xml`)

- 1.9 MB, 2,477 `<url>` entries.
- Each entry has `loc` (article URL), `lastmod`, `priority`, `changefreq`,
  and `image:image` with `image:title` / `image:caption`.
- `image:title` is the article title (inside an escaped `<![CDATA[...]]>`). So url, title and
  lastmod all come from the sitemap, no need to open each article.
- `lastmod` dates: 20 entries on 2026-09-18..20, the rest on 2026-09-21..25 (445-534 per day).
  The file name does not always match the actual date range, so I'll take one extra bucket on
  both sides, then filter by date.
- 97 of 2,477 titles contain "ngân hàng" (case-insensitive).

Rough volume for the window: ~146 buckets x ~2,500 URLs = ~360,000 URLs, ~280 MB of raw XML
(git-ignored under `raw/news/`).

## Full download (2026-09-28)

- 146 bucket files (2024-09-21-25 to 2026-09-26-30), 185 MB, all HTTP 200, all with a closing
  `</urlset>`. Older buckets are smaller (~1.1 MB), so the earlier ~360k estimate was too high.
- 248,649 entries, 248,415 distinct URLs. Every calendar day in the window has entries
  (lowest: 173 on 2024-10-27, a Sunday).
- 232 URLs appear in two bucket files, each time with a different `lastmod`. So an article can
  show up again later with a new `lastmod`, which fits `lastmod` being a modification time.
  Staging has to keep one row per URL.

## Article URL IDs

Most URLs end in `-188YYMMDDhhmmssNNN.chn` (2,219 of 2,477). The 12 digits after `188` parse as
a timestamp. The other 258 URLs have a shorter suffix that doesn't parse this way.

For the 2,219 parseable URLs, `lastmod` minus the URL timestamp (hours):

| min | p25 | median | p75 | p95 | max |
|---|---|---|---|---|---|
| 0.0 | 0.0 | 0.01 | 0.69 | 11.85 | 127.17 |

`lastmod` was never earlier than the URL timestamp. 37 entries were more than 24 h later,
136 were on a different calendar date.

## Is `lastmod` the publish time? Not always.

Opened two articles and compared with the page's `article:published_time` meta tag
(same as the time shown in the byline):

| Article (URL ID) | URL timestamp | lastmod | article:published_time |
|---|---|---|---|
| `...can-nha-200m-cua-van-hugo-188260922110644333` | 2026-09-22 11:06 | 2026-09-22 16:53 | 2026-09-22 21:15 |
| `...ha-tang-can-gio-...-188260919131810841` | 2026-09-19 13:18 | 2026-09-24 20:28 | 2026-09-22 07:07 |

- Article 1: `lastmod` is about 4 h before the publish time. Same day, but on the other side of
  the 15:00 market close.
- Article 2: `lastmod` is 2.5 days after the publish time, on a different date.
- The URL timestamp may be a creation/draft time; in these examples it can be days before
  publication.

So far, `article:published_time` is the only field I've found that matches the displayed publish
time. Only two articles were checked, so this is not enough to decide yet. I'll test `lastmod` on
a larger sample in Phase 1 before choosing the timestamp for `reaction_date_key`.

## lastmod vs publish time, measured on a sample (2026-09-28)

Stratified sample of 50 articles (`ingest/sample_lastmod.py`, fixed seed), strata by
lastmod minus URL timestamp. Each timestamp mapped to a trading session: before 15:00 -> first
trading day on or after that date, from 15:00 -> first trading day after it
(`sql/04_quality/030_lastmod_sample_analysis.sql`).

| Stratum | Lag | Population | Sampled | Different session |
|---|---|---|---|---|
| A | < 1 h | 201,627 | 14 | 1 |
| B | 1-6 h | 25,378 | 14 | 0 |
| C | 6-24 h | 13,732 | 11 | 2 |
| D | >= 24 h | 5,320 | 11 | 8 |

- Weighted by stratum population: 8.4% of the 246,057 articles would get a different session
  from lastmod than from the real publish time. Unweighted (11/50) would say 22%.
- The 8.4% is rough. Stratum A is 82% of the population and rests on 1 mismatch in 14, so the
  real rate could be anywhere from a few percent to a few tens of percent.
- Stratum D (8 of 11 wrong) fits lastmod being a modification time.

Decision: lastmod is not used for `reaction_date_key`. See docs/decisions.md.

## Per-ticker endpoint

The page `https://cafef.vn/du-lieu/tin-doanh-nghiep/vcb/event.chn` loads its news list through this
request. I found the request in the page's inline script and checked it in a browser:

```
GET https://cafef.vn/du-lieu/Ajax/Events_RelatedNews_New.aspx
    ?symbol=VCB&floorID=0&configID=0&PageIndex=1&PageSize=30&Type=2
```

- Returns an HTML fragment (`<ul class="News_Title_Link">`), 30 items per page. Each item has a
  time (`<span class="timeTitle">dd/mm/yyyy HH:MM</span>`), a title and a link.
- Two kinds of links:
  - CafeF articles: `/...-188YYMMDDhhmmssNNN.chn`
  - Company disclosure pages: `/du-lieu/VCB-2982639/...chn`. Many of these show `00:00`, so only
    the date can be used as the event time.
- How far back: for VCB, page 1 goes from 2026-09-23 back to 2026-05-13, page 10 covers
  2023-04-26 to 2023-07-31. A 2-year window looks like roughly 7 pages per ticker, or about
  70 requests for all 10 tickers.
- The list time matched `article:published_time` for the 3 articles where I could read the meta
  tag (a 4th page didn't match my regex). So this endpoint seems to give the publish time,
  unlike `lastmod` in the sitemap. Still only a few articles; to be checked on the larger sample.
- The list is CafeF's own tagging of news to a ticker. Some items are about several banks
  (e.g. "Cổ đông VietinBank, BIDV, Vietcombank đón tin vui").

Side note for Phase 2: the VCB list has "23.7.2026, ngày GDKHQ trả cổ tức năm 2025 bằng tiền
(450 đ/cp)". That ex-date can be used to check whether VCI adjusts prices for cash dividends.

## Loading into the raw layer (2026-09-29)

Full page fetch: 10,966 candidates, 10,959 saved, 7 returned 404, 2 HTTP 504 that succeeded on retry.

- `raw.raw_article`: 248,649 rows, 248,415 distinct URLs (234 extra rows: 232 URLs listed more than once, 230 of them twice and
  2 three times).
- Titles: CafeF puts HTML entities inside the CDATA ("Lynk &amp; Co"). 1,134 titles still had
  `&amp;` after one decode; the loader now decodes the inner text once more.
- 39 sitemap titles are not in Unicode NFC (decomposed Vietnamese letters). Small, but it matters
  for text matching in Phase 5.
- Fetched pages without `article:published_time`: 94 of 10,959 (0.9%) after the full fetch
  (47 of ~5.1k in the first look). They are long-form sponsored pages with no date meta at all.
  They fall back to lastmod (`time_source`).
- Sitemap title vs page `og:title`: 593 of 10,959 (5.4%) differ in wording, not only in spaces (e.g. a longer
  headline in the sitemap, a shorter one in og:title). Which title the Phase 5 rules read is a
  decision for that phase.

## Open questions

1. Whether the per-ticker list time always equals `article:published_time`, and what `00:00`
   means for disclosures (published before the open, or time unknown).
2. Whether company disclosures count as news articles or as a separate event type.
