-- Phase 3, before dim_ticker: did any of the 10 banks change its legal name inside the window?
-- Two sources in staging: CafeF article titles (stg_article) and the banks' own disclosures
-- (stg_ticker_news). Branch and transaction-office renames are left out in query 2.
USE BankingSectorIntelligence;

-- 1. Article titles about a rename that mention one of the banks.
SELECT CAST(a.publish_time_local AS date) AS pub_date, a.sitemap_title, a.url
FROM stg.stg_article a
WHERE (a.sitemap_title LIKE N'%đổi tên%' OR a.sitemap_title LIKE N'%tên mới%'
       OR a.sitemap_title LIKE N'%tên gọi mới%' OR a.sitemap_title LIKE N'%thay đổi tên%')
  AND (a.sitemap_title LIKE N'%Vietcombank%' OR a.sitemap_title LIKE N'%VietinBank%'
       OR a.sitemap_title LIKE N'%Techcombank%' OR a.sitemap_title LIKE N'%MBBank%'
       OR a.sitemap_title LIKE N'% MB %'        OR a.sitemap_title LIKE N'%ACB%'
       OR a.sitemap_title LIKE N'%VPBank%'      OR a.sitemap_title LIKE N'%Sacombank%'
       OR a.sitemap_title LIKE N'%HDBank%'      OR a.sitemap_title LIKE N'%TPBank%'
       OR a.sitemap_title LIKE N'%SHB%'
       OR a.sitemap_title LIKE N'%Ngoại thương%' OR a.sitemap_title LIKE N'%Công thương%'
       OR a.sitemap_title LIKE N'%Kỹ thương%'    OR a.sitemap_title LIKE N'%Quân đội%'
       OR a.sitemap_title LIKE N'%Á Châu%'       OR a.sitemap_title LIKE N'%Thịnh Vượng%'
       OR a.sitemap_title LIKE N'%Thương Tín%'   OR a.sitemap_title LIKE N'%Tiên Phong%'
       OR a.sitemap_title LIKE N'%Sài Gòn%Hà Nội%' OR a.sitemap_title LIKE N'%Phát triển%Hồ Chí Minh%')
ORDER BY pub_date;

-- 2. Disclosures about a name or the operating licence, without branch / office renames.
SELECT n.ticker, CAST(n.list_time_local AS date) AS list_date, n.title
FROM stg.stg_ticker_news n
WHERE n.item_kind = 'disclosure'
  AND (n.title LIKE N'%tên%' OR n.title LIKE N'%Giấy phép thành lập%')
  AND n.title NOT LIKE N'%chi nhánh%'
  AND n.title NOT LIKE N'%phòng giao dịch%'
  AND n.title NOT LIKE N'%PGD%'
  AND n.title NOT LIKE N'%Phòng GD%'
  AND n.title NOT LIKE N'%CN %'
ORDER BY n.ticker, list_date;
