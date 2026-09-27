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

## Open questions

1. Which timestamp to use for the publish time (see above).
2. Whether the per-ticker list time always equals `article:published_time`, and what `00:00`
   means for disclosures (published before the open, or time unknown).
3. Whether the 258 URLs with short IDs follow another pattern.
4. Whether company disclosures count as news articles or as a separate event type.
