USE BankingSectorIntelligence;
GO
CREATE OR ALTER VIEW mart.v_pbi_ticker_session AS
SELECT r.ticker,
       r.date_key,
       r.session_seq,
       p.close_price,
       r.ret,
       r.sector_ret,
       r.excess_ret,
       r.ticker_index,
       r.rs,
       c.corr_60,
       z.z,
       i.out_3,
       e.episode_key,
       CASE
            WHEN z.z IS NULL THEN NULL
            WHEN e.episode_key IS NOT NULL THEN 1
            ELSE 0
       END AS is_alert
FROM mart.v_relative_strength r
LEFT JOIN mart.v_price_session p  ON r.ticker = p.ticker AND r.session_seq = p.session_seq
LEFT JOIN mart.v_rolling_corr c   ON r.ticker = c.ticker AND r.session_seq = c.session_seq
LEFT JOIN mart.v_excess_zscore z  ON r.ticker = z.ticker AND r.session_seq = z.session_seq
LEFT JOIN mart.v_excess_iqr i     ON r.ticker = i.ticker AND r.session_seq = i.session_seq
LEFT JOIN mart.v_pbi_episode e    ON r.ticker = e.ticker AND r.session_seq BETWEEN e.start_seq AND e.end_seq;
GO