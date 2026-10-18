#!/bin/bash
# Regenerate data and reload it into the running Postgres container.
#   ./scripts/reload.sh              clean data ending yesterday
#   ./scripts/reload.sh --bad-data   corrupt the last day (to demo the data-quality gate)
set -e
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1      # Git Bash on Windows: don't rewrite /sql/... into C:/Program Files/Git/sql/...
PY=python3
if ! $PY --version >/dev/null 2>&1; then PY=python; fi   # Windows usually has "python", not "python3"
$PY generator/generate_data.py "$@"
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U lane -d lanewatch -f /sql/02_load.sql
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U lane -d lanewatch -f /sql/06_refresh.sql
echo "Reloaded. Run the workflow in n8n to see the result."
