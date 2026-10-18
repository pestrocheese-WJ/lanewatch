-- LaneWatch KPI tables. Every metric is keyed on the day the EVENT happened
-- (attempt day, delivery day, hub departure day), so "yesterday" is always complete.
--
-- The three daily KPI tables are MATERIALIZED views: the workflow refreshes them once per run
-- (sql/06_refresh.sql) after the data-quality gate passes, so the report query reads small
-- pre-aggregated tables instead of re-scanning every parcel.
DROP MATERIALIZED VIEW IF EXISTS v_lane_daily, v_hub_daily, v_linehaul_daily CASCADE;
DROP VIEW IF EXISTS v_hub_events CASCADE;

-- ---------------------------------------------------------------------------
-- Lane x day: last-mile and SLA metrics
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW v_lane_daily AS
WITH a AS (
    SELECT lane,
           attempt_at::date AS day,
           count(*) FILTER (WHERE attempt_no = 1)                         AS first_attempts,
           count(*) FILTER (WHERE attempt_no = 1 AND outcome = 'success') AS first_success,
           count(*)                                                       AS attempts,
           count(*) FILTER (WHERE outcome = 'success')                    AS successes
    FROM attempts
    GROUP BY 1, 2
),
-- parcels whose journey ENDED that day (delivered, or returned after the 3rd failed attempt)
closed AS (
    SELECT p.lane,
           coalesce(p.delivered_at, last_a.attempt_at)::date AS day,
           count(*)                                          AS closed,
           count(*) FILTER (WHERE p.final_status = 'delivered') AS closed_delivered,
           sum(p.attempt_count)                              AS closed_attempts,
           count(*) FILTER (WHERE p.final_status = 'delivered'
                            AND p.delivered_at < (p.created_at::date + p.sla_days + 1)) AS delivered_on_time
    FROM parcels p
    LEFT JOIN LATERAL (
        SELECT max(attempt_at) AS attempt_at FROM attempts x WHERE x.parcel_id = p.parcel_id
    ) last_a ON p.final_status = 'returned'
    WHERE p.final_status IN ('delivered', 'returned')
    GROUP BY 1, 2
)
SELECT coalesce(a.lane, c.lane) AS lane,
       coalesce(a.day, c.day)   AS day,
       coalesce(a.first_attempts, 0)   AS first_attempts,
       coalesce(a.first_success, 0)    AS first_success,
       coalesce(a.attempts, 0)         AS attempts,
       coalesce(a.successes, 0)        AS successes,
       coalesce(c.closed, 0)           AS closed,
       coalesce(c.closed_delivered, 0) AS closed_delivered,
       coalesce(c.closed_attempts, 0)  AS closed_attempts,
       coalesce(c.delivered_on_time, 0) AS delivered_on_time,
       -- ratios (NULL when there is nothing to divide)
       round(a.first_success::numeric / nullif(a.first_attempts, 0), 4)   AS first_attempt_sr,   -- "SFR" at first attempt
       round(a.successes::numeric / nullif(a.attempts, 0), 4)             AS attempt_sr,         -- all attempts
       round(c.closed_delivered::numeric / nullif(c.closed, 0), 4)        AS final_delivered_rate,
       round(c.delivered_on_time::numeric / nullif(c.closed_delivered, 0), 4) AS lead_time_compliance,
       round(c.closed_attempts::numeric / nullif(c.closed, 0), 3)         AS attempts_per_parcel
FROM a
FULL JOIN closed c ON c.lane = a.lane AND c.day = a.day;

-- ---------------------------------------------------------------------------
-- Hub x day: processing (dwell) time, inbound and outbound
-- ---------------------------------------------------------------------------
CREATE VIEW v_hub_events AS
SELECT origin_hub AS hub_code, 'outbound' AS flow, lane, origin_in_at AS in_at, origin_out_at AS out_at
FROM parcels WHERE origin_out_at IS NOT NULL
UNION ALL
SELECT dest_hub, 'inbound', lane, dest_in_at, dest_out_at
FROM parcels WHERE dest_out_at IS NOT NULL;

CREATE MATERIALIZED VIEW v_hub_daily AS
SELECT hub_code,
       flow,
       out_at::date AS day,
       count(*) AS parcels,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM out_at - in_at)) / 3600)::numeric, 1) AS dwell_p50_h,
       round((percentile_cont(0.9) WITHIN GROUP (ORDER BY extract(epoch FROM out_at - in_at)) / 3600)::numeric, 1) AS dwell_p90_h
FROM v_hub_events
GROUP BY 1, 2, 3;

-- ---------------------------------------------------------------------------
-- Lane x day: linehaul (hub-to-hub) transit time
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW v_linehaul_daily AS
SELECT lane,
       dest_in_at::date AS day,
       count(*) AS parcels,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM dest_in_at - origin_out_at)) / 3600)::numeric, 1) AS transit_p50_h
FROM parcels
WHERE dest_in_at IS NOT NULL
GROUP BY 1, 2;

CREATE UNIQUE INDEX ON v_lane_daily (lane, day);
CREATE UNIQUE INDEX ON v_hub_daily (hub_code, flow, day);
CREATE UNIQUE INDEX ON v_linehaul_daily (lane, day);
