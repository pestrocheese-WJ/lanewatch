# Windows PowerShell version of reload.sh
#   .\scripts\reload.ps1              clean data ending yesterday
#   .\scripts\reload.ps1 --bad-data   corrupt the last day (to demo the data-quality gate)
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
python generator/generate_data.py @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U lane -d lanewatch -f /sql/02_load.sql
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U lane -d lanewatch -f /sql/06_refresh.sql
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "Reloaded. Run the workflow in n8n to see the result."
