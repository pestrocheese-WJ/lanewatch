-- Dashboard tab "lane_summary": last 7 days vs the 4 weeks before, per lane.
-- Status = Problem when either KPI dropped 5pp or more.
WITH d AS (SELECT max(day) AS last FROM v_lane_daily),
agg AS (
  SELECT lane,
    sum(first_success) FILTER (WHERE day > d.last - 7)::numeric / nullif(sum(first_attempts) FILTER (WHERE day > d.last - 7),0) AS fasr_7,
    sum(first_success) FILTER (WHERE day BETWEEN d.last - 34 AND d.last - 7)::numeric / nullif(sum(first_attempts) FILTER (WHERE day BETWEEN d.last - 34 AND d.last - 7),0) AS fasr_b,
    sum(delivered_on_time) FILTER (WHERE day > d.last - 7)::numeric / nullif(sum(closed_delivered) FILTER (WHERE day > d.last - 7),0) AS ltc_7,
    sum(delivered_on_time) FILTER (WHERE day BETWEEN d.last - 34 AND d.last - 7)::numeric / nullif(sum(closed_delivered) FILTER (WHERE day BETWEEN d.last - 34 AND d.last - 7),0) AS ltc_b
  FROM v_lane_daily, d GROUP BY lane)
SELECT lane,
  round(fasr_b*100,1) AS "First-attempt % (normal)",
  round(fasr_7*100,1) AS "First-attempt % (last 7d)",
  round((fasr_7-fasr_b)*100,1) AS "First-attempt change (pp)",
  round(ltc_b*100,1) AS "On-time % (normal)",
  round(ltc_7*100,1) AS "On-time % (last 7d)",
  round((ltc_7-ltc_b)*100,1) AS "On-time change (pp)",
  CASE WHEN (fasr_7-fasr_b)*100 <= -5 OR (ltc_7-ltc_b)*100 <= -5 THEN 'Problem' ELSE 'OK' END AS "Status"
FROM agg ORDER BY least((fasr_7-fasr_b),(ltc_7-ltc_b));
