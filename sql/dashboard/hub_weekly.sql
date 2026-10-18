-- Dashboard tab "hub_weekly": median inbound processing time per hub per week.
SELECT hub_code AS hub,
       'W' || to_char(date_trunc('week', day), 'MM-DD') AS week_start,
       round(avg(dwell_p50_h), 1) AS median_processing_h
FROM v_hub_daily
WHERE flow = 'inbound'
  AND day >= (SELECT date_trunc('week', min(day)) + interval '7 days' FROM v_hub_daily)
GROUP BY 1, 2
ORDER BY 1, 2;
