-- mart.v_relative_strength: one row per ticker per session, ticker against the sector.
--   excess_ret  ret - sector_ret; NULL at session 1. Input to the z-score (6.7): it has no trend.
--   rs          100 * ticker_index / sector_index; 100 at session 1. For charts only: it trends,
--               so it is never used for z-scores.
-- v_sector_index has one row per session_seq, so the join does not multiply rows.
USE BankingSectorIntelligence;
GO

CREATE OR ALTER VIEW mart.v_relative_strength AS
SELECT t.ticker, t.session_seq, t.date_key, t.full_date,
       t.ret, s.sector_ret,
       t.ret - s.sector_ret AS excess_ret,
       t.ticker_index, s.sector_index,
       100 * t.ticker_index / s.sector_index AS rs
FROM mart.v_ticker_index t
JOIN mart.v_sector_index s ON s.session_seq = t.session_seq;