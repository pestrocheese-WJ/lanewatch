"""
Backtest: replay the detection rules for every day in a window and print what would have been flagged.
Shows (a) how quiet the system is on normal days and (b) how early each planted problem is caught.

    python scripts/backtest.py --start 2026-09-17 --end 2026-10-17
Needs psql on PATH. Connection via PGHOST/PGUSER/PGPASSWORD/PGDATABASE
(defaults match docker-compose: localhost / lane / lane / lanewatch).
"""
import argparse
import json
import os
import subprocess
from datetime import date, timedelta

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
env = {**os.environ}
for k, v in {"PGHOST": "localhost", "PGUSER": "lane", "PGPASSWORD": "lane", "PGDATABASE": "lanewatch"}.items():
    env.setdefault(k, v)

ap = argparse.ArgumentParser()
ap.add_argument("--start", required=True)
ap.add_argument("--end", required=True)
args = ap.parse_args()

sql = open(os.path.join(ROOT, "sql", "05_lane_report.sql"), encoding="utf-8").read()
d, end = date.fromisoformat(args.start), date.fromisoformat(args.end)
quiet = 0
total = 0
print(f"{'date':<11} {'day':<4} lanes flagged / hubs flagged")
while d <= end:
    q = sql.replace("$1", f"'{d}'")
    out = subprocess.run(["psql", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1", "-c", q],
                         capture_output=True, text=True, env=env, check=True).stdout
    p = json.loads(out)
    lanes = [f"{l['lane']}({l['severity'][0]})" for l in p["lanes_flagged"]]
    hubs = sorted({f"{h['hub_code']}:{h['flow'][:3]} {h['dwell_p50_h']}h" for h in p["hubs_flagged"]})
    if not lanes and not hubs:
        quiet += 1
    total += 1
    print(f"{d} {d.strftime('%a'):<4} {', '.join(lanes) or '-'}  /  {', '.join(hubs) or '-'}")
    d += timedelta(days=1)
print(f"\n{quiet}/{total} days with no flags.  (h)=high (m)=medium severity")
