-- LaneWatch daily lane & hub report.
-- $1 = report date (YYYY-MM-DD). Returns ONE row with a single JSON column `payload`.
--
-- Detection is done HERE, in plain SQL, not by the LLM:
--   * a lane KPI is flagged when it is BOTH statistically worse than its own 28-day baseline
--     (z-score of a proportion) AND practically worse (drop of at least min_delta_pp),
--     OR when it is below target and also clearly below its own baseline (z <= -2.5).
--     Requiring both "statistical" and "practical" significance keeps small lanes from paging people on noise.
--   * a hub is flagged when its median processing time is 2x its usual for that weekday,
--     or above target AND 1.5x its usual. Known weekly patterns (weekend backlog) go to recurring_patterns.
-- Claude only gets the flagged items plus the evidence below, and is asked to EXPLAIN them.
-- All rates are expressed in percent (1 decimal) so the numbers Claude quotes can be checked exactly.
WITH p AS (SELECT $1::date AS d),
t AS (
    SELECT max(target) FILTER (WHERE kpi = 'first_attempt_sr_min')     AS fasr_min,
           max(target) FILTER (WHERE kpi = 'lead_time_compliance_min') AS ltc_min,
           max(target) FILTER (WHERE kpi = 'hub_dwell_p50_max_h')      AS dwell_max,
           max(target) FILTER (WHERE kpi = 'z_alert')                  AS z_alert,
           max(target) FILTER (WHERE kpi = 'min_daily_volume')         AS min_vol,
           max(target) FILTER (WHERE kpi = 'min_delta_pp')             AS min_delta_pp
    FROM kpi_targets
),
cur AS (SELECT v.* FROM v_lane_daily v, p WHERE v.day = p.d),
base AS (
    SELECT lane,
           sum(first_attempts) AS fa, sum(first_success) AS fs,
           sum(closed) AS cl, sum(closed_delivered) AS cd,
           sum(closed_attempts) AS ca, sum(delivered_on_time) AS dot
    FROM v_lane_daily, p
    WHERE day BETWEEN p.d - 28 AND p.d - 1
    GROUP BY lane
),
m AS (
    SELECT l.lane, l.origin_hub, l.dest_hub, l.sla_days,
           coalesce(c.first_attempts, 0)   AS first_attempts,
           coalesce(c.closed_delivered, 0) AS delivered,
           c.first_attempt_sr                         AS fasr,
           round(b.fs::numeric / nullif(b.fa, 0), 4)  AS fasr_b,
           c.lead_time_compliance                     AS ltc,
           round(b.dot::numeric / nullif(b.cd, 0), 4) AS ltc_b,
           c.final_delivered_rate                     AS fdr,
           round(b.cd::numeric / nullif(b.cl, 0), 4)  AS fdr_b,
           c.attempts_per_parcel                      AS app,
           round(b.ca::numeric / nullif(b.cl, 0), 2)  AS app_b
    FROM lanes l
    LEFT JOIN cur c  ON c.lane = l.lane
    LEFT JOIN base b ON b.lane = l.lane
),
z AS (
    SELECT m.*,
           round((fasr - fasr_b) / nullif(sqrt(fasr_b * (1 - fasr_b) / nullif(first_attempts, 0)), 0), 1) AS z_fasr,
           round((ltc - ltc_b)   / nullif(sqrt(ltc_b * (1 - ltc_b) / nullif(delivered, 0)), 0), 1)        AS z_ltc
    FROM m
),
f AS (
    SELECT z.*,
           (first_attempts >= t.min_vol AND (
                (z_fasr <= t.z_alert AND (fasr - fasr_b) * 100 <= -t.min_delta_pp)
             OR (fasr < t.fasr_min AND z_fasr <= -2.5))) AS fasr_flag,
           (delivered >= t.min_vol AND (
                (z_ltc <= t.z_alert AND (ltc - ltc_b) * 100 <= -t.min_delta_pp)
             OR (ltc < t.ltc_min AND z_ltc <= -2.5))) AS ltc_flag,
           t.fasr_min, t.ltc_min
    FROM z, t
),
lane_rows AS (
    SELECT f.*,
           (fasr_flag OR ltc_flag) AS flagged,
           CASE WHEN (fasr_flag AND ltc_flag)
                  OR fasr < fasr_min - 0.10 OR ltc < ltc_min - 0.10
                  OR least(z_fasr, z_ltc) <= -6 THEN 'high'
                WHEN (fasr_flag OR ltc_flag) THEN 'medium' END AS severity
    FROM f
),
-- ---------------- hubs ----------------
hub_cur AS (SELECT h.* FROM v_hub_daily h, p WHERE h.day = p.d),
hub_base AS (   -- same weekday, previous 4 weeks (hub speed has a strong weekday pattern)
    SELECT hub_code, flow, round(avg(dwell_p50_h), 1) AS p50_b, round(avg(dwell_p90_h), 1) AS p90_b
    FROM v_hub_daily, p
    WHERE day IN (p.d - 7, p.d - 14, p.d - 21, p.d - 28)
    GROUP BY 1, 2
),
hub_rows AS (
    SELECT c.hub_code, hb.hub_name, c.flow, c.parcels,
           c.dwell_p50_h, b.p50_b AS dwell_p50_baseline_h,
           c.dwell_p90_h, b.p90_b AS dwell_p90_baseline_h,
           (c.dwell_p50_h > 2 * b.p50_b OR (c.dwell_p50_h > t.dwell_max AND c.dwell_p50_h > 1.5 * b.p50_b)) AS flagged
    FROM hub_cur c
    JOIN hub_base b USING (hub_code, flow)
    LEFT JOIN hubs hb USING (hub_code)
    CROSS JOIN t
),
-- ---------------- recurring patterns (last 28 days) ----------------
patterns AS (
    SELECT hub_code, flow,
           round(avg(dwell_p50_h) FILTER (WHERE extract(isodow FROM day) < 6), 1)  AS weekday_p50_h,
           round(avg(dwell_p50_h) FILTER (WHERE extract(isodow FROM day) >= 6), 1) AS weekend_p50_h
    FROM v_hub_daily, p
    WHERE day BETWEEN p.d - 28 AND p.d - 1
    GROUP BY 1, 2
),
-- ---------------- network totals ----------------
net AS (
    SELECT sum(first_attempts) AS fa, sum(first_success) AS fs,
           sum(closed_delivered) AS cd, sum(delivered_on_time) AS dot
    FROM cur
),
net_b AS (
    SELECT sum(first_attempts) AS fa, sum(first_success) AS fs,
           sum(closed_delivered) AS cd, sum(delivered_on_time) AS dot
    FROM v_lane_daily, p WHERE day BETWEEN p.d - 28 AND p.d - 1
)
SELECT json_build_object(
    'report_date', (SELECT d FROM p)::text,
    'baseline_window', '28 days before report date',
    'targets', (SELECT json_build_object(
                    'first_attempt_success_min_pct', round(fasr_min * 100, 1),
                    'lead_time_compliance_min_pct', round(ltc_min * 100, 1),
                    'hub_dwell_p50_max_h', dwell_max,
                    'z_alert', z_alert) FROM t),
    'network', (SELECT json_build_object(
                    'first_attempts', net.fa,
                    'first_attempt_success_pct', round(100.0 * net.fs / nullif(net.fa, 0), 1),
                    'first_attempt_success_baseline_pct', round(100.0 * net_b.fs / nullif(net_b.fa, 0), 1),
                    'lead_time_compliance_pct', round(100.0 * net.dot / nullif(net.cd, 0), 1),
                    'lead_time_compliance_baseline_pct', round(100.0 * net_b.dot / nullif(net_b.cd, 0), 1),
                    'lanes_total', (SELECT count(*) FROM lane_rows),
                    'lanes_flagged', (SELECT count(*) FROM lane_rows WHERE flagged),
                    'hubs_flagged', (SELECT count(DISTINCT hub_code) FROM hub_rows WHERE flagged))
                FROM net, net_b),

    -- flagged lanes, with the evidence Claude needs to explain them
    'lanes_flagged', coalesce((
        SELECT json_agg(json_build_object(
            'lane', r.lane, 'origin_hub', r.origin_hub, 'dest_hub', r.dest_hub, 'sla_days', r.sla_days,
            'severity', r.severity,
            'breaches', array_remove(ARRAY[CASE WHEN r.fasr_flag THEN 'first_attempt_success' END,
                                           CASE WHEN r.ltc_flag  THEN 'lead_time_compliance' END], NULL),
            'kpis', json_build_object(
                'first_attempts', r.first_attempts,
                'first_attempt_success_pct', round(r.fasr * 100, 1),
                'first_attempt_success_baseline_pct', round(r.fasr_b * 100, 1),
                'first_attempt_success_delta_pp', round((r.fasr - r.fasr_b) * 100, 1),
                'first_attempt_success_z', r.z_fasr,
                'delivered', r.delivered,
                'lead_time_compliance_pct', round(r.ltc * 100, 1),
                'lead_time_compliance_baseline_pct', round(r.ltc_b * 100, 1),
                'lead_time_compliance_delta_pp', round((r.ltc - r.ltc_b) * 100, 1),
                'lead_time_compliance_z', r.z_ltc,
                'final_delivered_rate_pct', round(r.fdr * 100, 1),
                'final_delivered_rate_baseline_pct', round(r.fdr_b * 100, 1),
                'attempts_per_parcel', round(r.app, 2),
                'attempts_per_parcel_baseline', r.app_b),

            -- why did first attempts fail? today vs baseline mix
            'fail_reasons_first_attempt', (
                SELECT json_agg(json_build_object(
                           'reason', reason, 'today_count', tn,
                           'today_share_pct', ts, 'baseline_share_pct', bs) ORDER BY tn DESC, bs DESC)
                FROM (
                    SELECT coalesce(a.fail_reason, 'unknown') AS reason,
                           count(*) FILTER (WHERE a.attempt_at::date = p.d) AS tn,
                           round(100.0 * count(*) FILTER (WHERE a.attempt_at::date = p.d)
                                 / nullif(sum(count(*) FILTER (WHERE a.attempt_at::date = p.d)) OVER (), 0), 1) AS ts,
                           round(100.0 * count(*) FILTER (WHERE a.attempt_at::date < p.d)
                                 / nullif(sum(count(*) FILTER (WHERE a.attempt_at::date < p.d)) OVER (), 0), 1) AS bs
                    FROM attempts a, p
                    WHERE a.lane = r.lane AND a.attempt_no = 1 AND a.outcome = 'fail'
                      AND a.attempt_at::date BETWEEN p.d - 28 AND p.d
                    GROUP BY 1
                ) x),

            -- when did first attempts fail? failure rate by time of day, today vs baseline
            'first_attempt_fail_rate_by_time', (
                SELECT json_agg(json_build_object(
                           'slot', slot, 'today_attempts', tn,
                           'today_fail_pct', tf, 'baseline_fail_pct', bf) ORDER BY slot)
                FROM (
                    SELECT CASE WHEN extract(hour FROM a.attempt_at) < 12 THEN '1_morning_09_12'
                                WHEN extract(hour FROM a.attempt_at) < 17 THEN '2_afternoon_12_17'
                                ELSE '3_evening_17_20' END AS slot,
                           count(*) FILTER (WHERE a.attempt_at::date = p.d) AS tn,
                           round(100.0 * count(*) FILTER (WHERE a.attempt_at::date = p.d AND a.outcome = 'fail')
                                 / nullif(count(*) FILTER (WHERE a.attempt_at::date = p.d), 0), 1) AS tf,
                           round(100.0 * count(*) FILTER (WHERE a.attempt_at::date < p.d AND a.outcome = 'fail')
                                 / nullif(count(*) FILTER (WHERE a.attempt_at::date < p.d), 0), 1) AS bf
                    FROM attempts a, p
                    WHERE a.lane = r.lane AND a.attempt_no = 1
                      AND a.attempt_at::date BETWEEN p.d - 28 AND p.d
                    GROUP BY 1
                ) y),

            -- where in the network is time being lost? hub processing + linehaul, today vs baseline
            'time_breakdown_h', json_build_object(
                'origin_hub_dwell_p50_today', (SELECT dwell_p50_h FROM v_hub_daily h, p WHERE h.hub_code = r.origin_hub AND h.flow = 'outbound' AND h.day = p.d),
                'origin_hub_dwell_p50_baseline', (SELECT round(avg(dwell_p50_h), 1) FROM v_hub_daily h, p WHERE h.hub_code = r.origin_hub AND h.flow = 'outbound' AND h.day BETWEEN p.d - 28 AND p.d - 1),
                'linehaul_p50_today', (SELECT transit_p50_h FROM v_linehaul_daily x, p WHERE x.lane = r.lane AND x.day = p.d),
                'linehaul_p50_baseline', (SELECT round(avg(transit_p50_h), 1) FROM v_linehaul_daily x, p WHERE x.lane = r.lane AND x.day BETWEEN p.d - 28 AND p.d - 1),
                'dest_hub_dwell_p50_today', (SELECT dwell_p50_h FROM v_hub_daily h, p WHERE h.hub_code = r.dest_hub AND h.flow = 'inbound' AND h.day = p.d),
                'dest_hub_dwell_p50_baseline', (SELECT round(avg(dwell_p50_h), 1) FROM v_hub_daily h, p WHERE h.hub_code = r.dest_hub AND h.flow = 'inbound' AND h.day BETWEEN p.d - 28 AND p.d - 1)),

            -- is it new or ongoing? last 14 days, oldest first
            'trend_14d', (
                SELECT json_build_object(
                    'first_attempt_success_pct', json_agg(round(first_attempt_sr * 100, 1) ORDER BY day),
                    'lead_time_compliance_pct',  json_agg(round(lead_time_compliance * 100, 1) ORDER BY day))
                FROM v_lane_daily v, p WHERE v.lane = r.lane AND v.day BETWEEN p.d - 13 AND p.d)
        ) ORDER BY (r.severity = 'high') DESC, least(r.z_fasr, r.z_ltc))
        FROM lane_rows r CROSS JOIN p
        WHERE r.flagged), '[]'::json),

    'hubs_flagged', coalesce((
        SELECT json_agg(json_build_object(
            'hub_code', h.hub_code, 'hub_name', h.hub_name, 'flow', h.flow, 'parcels', h.parcels,
            'dwell_p50_h', h.dwell_p50_h, 'dwell_p50_same_weekday_baseline_h', h.dwell_p50_baseline_h,
            'dwell_p90_h', h.dwell_p90_h, 'dwell_p90_same_weekday_baseline_h', h.dwell_p90_baseline_h,
            'dwell_p50_trend_14d', (SELECT json_agg(v.dwell_p50_h ORDER BY v.day) FROM v_hub_daily v, p
                                    WHERE v.hub_code = h.hub_code AND v.flow = h.flow AND v.day BETWEEN p.d - 13 AND p.d),
            'lanes_through_hub', (SELECT json_agg(l.lane ORDER BY l.lane) FROM lanes l
                                  WHERE (h.flow = 'inbound' AND l.dest_hub = h.hub_code)
                                     OR (h.flow = 'outbound' AND l.origin_hub = h.hub_code))
        ) ORDER BY h.dwell_p50_h DESC)
        FROM hub_rows h WHERE h.flagged), '[]'::json),

    'recurring_patterns', coalesce((
        SELECT json_agg(json_build_object(
            'pattern', 'weekend_slowdown', 'hub_code', hub_code, 'flow', flow,
            'weekday_dwell_p50_h', weekday_p50_h, 'weekend_dwell_p50_h', weekend_p50_h))
        FROM patterns WHERE weekend_p50_h >= 1.5 * weekday_p50_h), '[]'::json),

    -- compact view of every lane, for the Google Sheet / dashboard
    'all_lanes', (
        SELECT json_agg(json_build_object(
            'lane', lane, 'flagged', flagged, 'severity', severity,
            'first_attempts', first_attempts,
            'first_attempt_success_pct', round(fasr * 100, 1),
            'lead_time_compliance_pct', round(ltc * 100, 1),
            'final_delivered_rate_pct', round(fdr * 100, 1),
            'attempts_per_parcel', round(app, 2)) ORDER BY lane)
        FROM lane_rows)
) AS payload;
