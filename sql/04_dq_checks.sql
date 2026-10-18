-- LaneWatch data-quality gate.
-- $1 = report date (YYYY-MM-DD). Returns ONE row: dq_pass (boolean) + checks (JSON array).
-- If dq_pass is false, the workflow sends an alert instead of an AI summary:
-- a confident summary built on a half-loaded feed is worse than no summary.
WITH p AS (SELECT $1::date AS d),
c AS (
    -- 1. Freshness: did data for the report date arrive at all?
    SELECT 'freshness' AS check_name,
           (SELECT coalesce(max(attempt_at)::date::text, 'none') FROM attempts) AS observed,
           'latest attempt date >= report date' AS rule,
           (SELECT coalesce(max(attempt_at)::date >= p.d, false) FROM attempts) AS ok
    FROM p
    UNION ALL
    -- 2. Volume: report-date attempts vs the same weekday over the previous 4 weeks
    SELECT 'volume_vs_same_weekday',
           round((SELECT count(*) FROM attempts WHERE attempt_at::date = p.d)::numeric
                 / nullif((SELECT count(*) / 4.0 FROM attempts
                           WHERE attempt_at::date IN (p.d - 7, p.d - 14, p.d - 21, p.d - 28)), 0), 2)::text,
           'ratio >= 0.70',
           coalesce((SELECT count(*) FROM attempts WHERE attempt_at::date = p.d)::numeric
                 / nullif((SELECT count(*) / 4.0 FROM attempts
                           WHERE attempt_at::date IN (p.d - 7, p.d - 14, p.d - 21, p.d - 28)), 0) >= 0.70, false)
    FROM p
    UNION ALL
    -- 3. Duplicates: the same (parcel, attempt number) must appear once
    SELECT 'duplicate_attempts',
           (SELECT count(*) FROM (
               SELECT parcel_id, attempt_no FROM attempts WHERE attempt_at::date = p.d
               GROUP BY 1, 2 HAVING count(*) > 1) x)::text,
           '0 duplicated (parcel_id, attempt_no)',
           (SELECT count(*) FROM (
               SELECT parcel_id, attempt_no FROM attempts WHERE attempt_at::date = p.d
               GROUP BY 1, 2 HAVING count(*) > 1) x) = 0
    FROM p
    UNION ALL
    -- 4. Null keys on parcels created in the last 7 days
    SELECT 'null_keys',
           (SELECT count(*) FROM parcels
            WHERE created_at::date BETWEEN p.d - 6 AND p.d
              AND (parcel_id IS NULL OR origin_hub IS NULL OR dest_hub IS NULL OR lane IS NULL))::text,
           '0 parcels missing parcel_id / hubs / lane',
           (SELECT count(*) FROM parcels
            WHERE created_at::date BETWEEN p.d - 6 AND p.d
              AND (parcel_id IS NULL OR origin_hub IS NULL OR dest_hub IS NULL OR lane IS NULL)) = 0
    FROM p
    UNION ALL
    -- 5. Unknown lanes: every attempt must belong to a lane we know about
    SELECT 'unknown_lanes',
           (SELECT count(*) FROM attempts a WHERE a.attempt_at::date = p.d
              AND NOT EXISTS (SELECT 1 FROM lanes l WHERE l.lane = a.lane))::text,
           '0 attempts on lanes missing from the lanes table',
           (SELECT count(*) FROM attempts a WHERE a.attempt_at::date = p.d
              AND NOT EXISTS (SELECT 1 FROM lanes l WHERE l.lane = a.lane)) = 0
    FROM p
    UNION ALL
    -- 6. Timeline sanity: no delivery before creation, no attempt before hub dispatch
    SELECT 'timeline_order',
           (SELECT count(*) FROM parcels
            WHERE created_at::date BETWEEN p.d - 6 AND p.d
              AND (delivered_at < created_at OR origin_out_at < origin_in_at OR dest_out_at < dest_in_at))::text,
           '0 parcels with impossible timestamp order',
           (SELECT count(*) FROM parcels
            WHERE created_at::date BETWEEN p.d - 6 AND p.d
              AND (delivered_at < created_at OR origin_out_at < origin_in_at OR dest_out_at < dest_in_at)) = 0
    FROM p
)
SELECT (SELECT d FROM p)::text AS report_date,
       bool_and(ok) AS dq_pass,
       count(*) FILTER (WHERE NOT ok) AS failed_checks,
       json_agg(json_build_object('check', check_name, 'observed', observed, 'rule', rule, 'ok', ok)) AS checks
FROM c;
