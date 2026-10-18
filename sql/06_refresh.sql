-- Run after every data load (the workflow does this right after the data-quality gate passes).
REFRESH MATERIALIZED VIEW v_lane_daily;
REFRESH MATERIALIZED VIEW v_hub_daily;
REFRESH MATERIALIZED VIEW v_linehaul_daily;
SELECT 'refreshed' AS status, (SELECT max(day) FROM v_lane_daily)::text AS latest_day;
