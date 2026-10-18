-- Load the generated CSVs. Paths are as seen by the Postgres server
-- (docker-compose mounts ./data at /data). Empty CSV fields load as NULL.
TRUNCATE hubs, lanes, parcels, attempts;

COPY hubs     FROM '/data/hubs.csv'     WITH (FORMAT csv, HEADER true);
COPY lanes    FROM '/data/lanes.csv'    WITH (FORMAT csv, HEADER true);
COPY parcels  FROM '/data/parcels.csv'  WITH (FORMAT csv, HEADER true);
COPY attempts FROM '/data/attempts.csv' WITH (FORMAT csv, HEADER true);

ANALYZE hubs; ANALYZE lanes; ANALYZE parcels; ANALYZE attempts;
