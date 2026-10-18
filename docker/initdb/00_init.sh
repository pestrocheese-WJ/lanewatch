#!/bin/bash
# Runs once, the first time the Postgres container starts with an empty volume.
set -e
for f in 01_schema 02_load 03_views 06_refresh; do
  echo "LaneWatch init: $f.sql"
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f "/sql/$f.sql"
done
