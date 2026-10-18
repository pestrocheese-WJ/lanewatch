-- LaneWatch schema
-- Raw landing tables deliberately have NO primary keys: if the feed sends duplicates,
-- we want them to land so the data-quality gate can detect and report them,
-- instead of the load crashing silently at 3 a.m.

DROP TABLE IF EXISTS attempts, parcels, lanes, hubs, kpi_targets CASCADE;

CREATE TABLE hubs (
    hub_code  TEXT,
    hub_name  TEXT,
    region    TEXT
);

CREATE TABLE lanes (
    lane       TEXT,
    origin_hub TEXT,
    dest_hub   TEXT,
    sla_days   INT
);

CREATE TABLE parcels (
    parcel_id     TEXT,
    created_at    TIMESTAMP,
    origin_hub    TEXT,
    dest_hub      TEXT,
    lane          TEXT,
    sla_days      INT,
    origin_in_at  TIMESTAMP,   -- scanned in at origin hub
    origin_out_at TIMESTAMP,   -- left origin hub on linehaul
    dest_in_at    TIMESTAMP,   -- arrived at destination hub
    dest_out_at   TIMESTAMP,   -- dispatched to last-mile courier
    final_status  TEXT,        -- delivered | returned | in_progress
    delivered_at  TIMESTAMP,
    attempt_count INT
);

CREATE TABLE attempts (
    parcel_id   TEXT,
    attempt_no  INT,
    attempt_at  TIMESTAMP,
    outcome     TEXT,          -- success | fail
    fail_reason TEXT,
    lane        TEXT,
    dest_hub    TEXT
);

CREATE INDEX ON attempts (attempt_at);
CREATE INDEX ON attempts (lane, attempt_at);
CREATE INDEX ON attempts (parcel_id);
CREATE INDEX ON parcels (parcel_id);
CREATE INDEX ON parcels (delivered_at);
CREATE INDEX ON parcels (origin_out_at);
CREATE INDEX ON parcels (dest_out_at);

-- Targets live in a table, not in code, so ops can tune them without touching the workflow.
CREATE TABLE IF NOT EXISTS kpi_targets (
    kpi         TEXT PRIMARY KEY,
    target      NUMERIC,
    description TEXT
);
INSERT INTO kpi_targets VALUES
    ('first_attempt_sr_min', 0.85, 'First-attempt success rate must stay at or above this'),
    ('lead_time_compliance_min', 0.90, 'Share of parcels delivered within SLA must stay at or above this'),
    ('hub_dwell_p50_max_h', 10, 'Median hub processing time (hours) must stay at or below this'),
    ('z_alert', -3.5, 'Flag a lane when today is this many standard errors worse than its 28-day baseline'),
    ('min_daily_volume', 30, 'Ignore lanes with fewer first attempts than this on the day'),
    ('min_delta_pp', 6, 'A statistically significant drop must also be at least this many percentage points')
ON CONFLICT (kpi) DO NOTHING;

-- Every workflow run writes one row here: this is the pipeline's own health log.
CREATE TABLE IF NOT EXISTS run_log (
    run_id      BIGSERIAL PRIMARY KEY,
    run_at      TIMESTAMPTZ DEFAULT now(),
    report_date DATE,
    dq_pass     BOOLEAN,
    lanes_flagged INT,
    hubs_flagged  INT,
    ai_status   TEXT,          -- validated | rejected_fallback | api_error_fallback | skipped
    notes       TEXT
);
