-- Dashboard tab "lane_weekly": one row per lane per week (Monday start).
-- Weekly instead of daily so the heatmap shows real shifts, not day-to-day noise.
-- The first, partial week of data is skipped.
SELECT lane,
       'W' || to_char(date_trunc('week', day), 'MM-DD') AS week_start,
       round(100.0 * sum(first_success) / nullif(sum(first_attempts), 0), 1)        AS first_attempt_pct,
       round(100.0 * sum(delivered_on_time) / nullif(sum(closed_delivered), 0), 1)  AS on_time_pct
FROM v_lane_daily
WHERE day >= (SELECT date_trunc('week', min(day)) + interval '7 days' FROM v_lane_daily)
GROUP BY 1, 2
ORDER BY 1, 2;
