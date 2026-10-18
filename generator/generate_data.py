"""
LaneWatch - synthetic last-mile logistics data generator.

Creates ~60 days of parcel + delivery-attempt data for a Thai delivery network
with problems hidden on purpose, so the automated pipeline has something real to find.

Planted problems (the pipeline is never told about these):
  1. KKC hub slowdown      - Khon Kaen hub processing time ramps up over the last ~10 days.
                             Hits every lane that touches KKC -> a HUB problem, not a lane problem.
  2. HDY afternoon failures - Lanes into Hat Yai: afternoon (12:00-17:00) delivery attempts
                             increasingly fail with "customer_not_available".
  3. CNX re-attempt trap   - BKK-CNX: first-attempt success drops sharply (address issues), but
                             couriers succeed on re-attempt, so the *final delivered rate* still
                             looks healthy. Only a first-attempt metric exposes it.
  4. BKK weekend backlog   - Bangkok SOC processes slower on Saturdays/Sundays (recurring, mild).

Usage:
  python generate_data.py                      # 60 days ending yesterday (Asia/Bangkok)
  python generate_data.py --end-date 2026-10-17
  python generate_data.py --bad-data           # also break the last day (tests the data-quality gate)
"""
import argparse
import csv
import os
from datetime import datetime, timedelta, date, time
from zoneinfo import ZoneInfo

import numpy as np

HUBS = [
    # code, name, region
    ("BKK", "Bangkok SOC", "Central"),
    ("CBI", "Chonburi Hub", "East"),
    ("AYA", "Ayutthaya Hub", "Central"),
    ("KKC", "Khon Kaen Hub", "Northeast"),
    ("UTH", "Udon Thani Hub", "Northeast"),
    ("CNX", "Chiang Mai Hub", "North"),
    ("PHS", "Phitsanulok Hub", "North"),
    ("HDY", "Hat Yai Hub", "South"),
    ("URT", "Surat Thani Hub", "South"),
]

# lane, origin, dest, sla_days, base daily volume, linehaul hours
LANES = [
    ("BKK-CBI", "BKK", "CBI", 2, 160, 2.0),
    ("BKK-AYA", "BKK", "AYA", 2, 120, 1.5),
    ("BKK-KKC", "BKK", "KKC", 2, 140, 6.0),
    ("BKK-UTH", "BKK", "UTH", 2, 90, 8.0),
    ("BKK-CNX", "BKK", "CNX", 2, 150, 10.0),
    ("BKK-PHS", "BKK", "PHS", 2, 80, 5.0),
    ("BKK-HDY", "BKK", "HDY", 3, 130, 13.0),
    ("BKK-URT", "BKK", "URT", 2, 90, 9.0),
    ("CBI-KKC", "CBI", "KKC", 2, 60, 6.5),
    ("CBI-HDY", "CBI", "HDY", 3, 50, 14.0),
    ("KKC-BKK", "KKC", "BKK", 2, 70, 6.0),
    ("CNX-BKK", "CNX", "BKK", 2, 80, 10.0),
]

FAIL_REASONS = ["customer_not_available", "address_issue", "customer_refused",
                "rescheduled_by_customer", "damaged", "other"]
FAIL_MIX = [0.45, 0.20, 0.10, 0.15, 0.03, 0.07]

BASE_ORIGIN_DWELL_H = 5.0
BASE_DEST_DWELL_H = 4.0


def ramp(day_idx, start, full, max_effect):
    """0 before `start`, linear up to `max_effect` at `full`, then flat."""
    if day_idx < start:
        return 0.0
    if day_idx >= full:
        return max_effect
    return max_effect * (day_idx - start) / (full - start)


def lognormal_hours(rng, median, sigma=0.35):
    return float(rng.lognormal(np.log(median), sigma))


def to_daytime(ts, rng):
    """Push an attempt time into delivery hours 09:00-19:59."""
    if ts.hour < 9:
        ts = datetime.combine(ts.date(), time(9)) + timedelta(minutes=int(rng.integers(0, 180)))
    elif ts.hour >= 20:
        ts = datetime.combine(ts.date() + timedelta(days=1), time(9)) + timedelta(minutes=int(rng.integers(0, 180)))
    return ts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--end-date", help="last day of data (YYYY-MM-DD). Default: yesterday in Asia/Bangkok")
    ap.add_argument("--days", type=int, default=60)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "data"))
    ap.add_argument("--bad-data", action="store_true", help="corrupt the last day to test the DQ gate")
    args = ap.parse_args()

    end = (date.fromisoformat(args.end_date) if args.end_date
           else datetime.now(ZoneInfo("Asia/Bangkok")).date() - timedelta(days=1))
    start = end - timedelta(days=args.days - 1)
    cutoff = datetime.combine(end, time(23, 59, 59))  # snapshot time: nothing after this exists yet
    rng = np.random.default_rng(args.seed)
    os.makedirs(args.out, exist_ok=True)

    # Problem windows, as day index (0 = start). Defaults to the last part of the window.
    D = args.days
    kkc_start, kkc_full = D - 12, D - 2        # KKC slowdown ramps over the last ~10 days
    hdy_start, hdy_full = D - 16, D - 3        # HDY afternoon failures
    cnx_start, cnx_full = D - 14, D - 6        # CNX re-attempt trap

    lane_fasr = {ln[0]: rng.uniform(0.90, 0.94) for ln in LANES}

    parcels, attempts = [], []
    pid = 0
    for d in range(D):
        day = start + timedelta(days=d)
        dow_factor = {0: 1.15, 1: 1.05, 2: 1.0, 3: 1.0, 4: 1.05, 5: 0.85, 6: 0.75}[day.weekday()]
        growth = 1 + 0.002 * d
        for lane, o, dst, sla, vol, haul in LANES:
            n = rng.poisson(vol * dow_factor * growth)
            for _ in range(n):
                pid += 1
                created = datetime.combine(day, time(8)) + timedelta(minutes=int(rng.integers(0, 14 * 60)))

                # --- origin hub processing ---
                origin_in = created + timedelta(hours=lognormal_hours(rng, 1.5, 0.5))
                od = BASE_ORIGIN_DWELL_H
                if o == "BKK" and origin_in.weekday() in (5, 6):
                    od += 9.0                                   # (4) weekend backlog
                if o == "KKC":
                    od += ramp(d, kkc_start, kkc_full, 18.0)    # (1) KKC slowdown, outbound side
                origin_out = origin_in + timedelta(hours=lognormal_hours(rng, od))

                # --- linehaul ---
                dest_in = origin_out + timedelta(hours=max(0.5, rng.normal(haul, haul * 0.12)))

                # --- destination hub processing ---
                dd = BASE_DEST_DWELL_H
                if dst == "KKC":
                    dd += ramp(d, kkc_start, kkc_full, 24.0)    # (1) KKC slowdown, inbound side
                dest_out = dest_in + timedelta(hours=lognormal_hours(rng, dd))

                # --- last mile attempts ---
                if dest_out.hour < 11:
                    first_at = datetime.combine(dest_out.date(), time(11)) + timedelta(minutes=int(rng.integers(0, 8 * 60)))
                else:
                    first_at = datetime.combine(dest_out.date() + timedelta(days=1), time(9)) + timedelta(minutes=int(rng.integers(0, 10 * 60)))
                first_at = to_daytime(first_at, rng)

                p_rows = []
                status, delivered_at = "in_progress", None
                at = first_at
                for k in range(1, 4):
                    if at > cutoff:
                        break
                    if k == 1:
                        p_ok = lane_fasr[lane]
                        reason_override = None
                        if dst == "HDY" and 12 <= at.hour < 17:        # (2) HDY afternoon failures
                            extra = ramp(d, hdy_start, hdy_full, 0.30)
                            if rng.random() < extra:
                                p_ok, reason_override = 0.0, "customer_not_available"
                        if lane == "BKK-CNX":                          # (3) CNX first-attempt drop
                            extra = ramp(d, cnx_start, cnx_full, 0.18)
                            if rng.random() < extra:
                                p_ok, reason_override = 0.0, "address_issue"
                    else:
                        p_ok = 0.97 if lane == "BKK-CNX" else 0.85      # (3) CNX re-attempts succeed
                        reason_override = None
                    ok = rng.random() < p_ok
                    reason = "" if ok else (reason_override or rng.choice(FAIL_REASONS, p=FAIL_MIX))
                    p_rows.append([f"P{pid:07d}", k, at.isoformat(sep=" ", timespec="seconds"),
                                   "success" if ok else "fail", reason, lane, dst])
                    if ok:
                        status, delivered_at = "delivered", at
                        break
                    if k == 3:
                        status = "returned"
                        break
                    nxt = datetime.combine(at.date() + timedelta(days=1), time(9)) + timedelta(minutes=int(rng.integers(0, 10 * 60)))
                    at = to_daytime(nxt, rng)

                def ts(x):
                    return x.isoformat(sep=" ", timespec="seconds") if x and x <= cutoff else ""

                parcels.append([f"P{pid:07d}", ts(created), o, dst, lane, sla,
                                ts(origin_in), ts(origin_out), ts(dest_in), ts(dest_out),
                                status, ts(delivered_at), len(p_rows)])
                attempts.extend(p_rows)

    # ---- optional: break the last day so the data-quality gate has something to catch ----
    if args.bad_data:
        last = end.isoformat()
        last_idx = [i for i, a in enumerate(attempts) if a[2].startswith(last)]
        drop = set(rng.choice(last_idx, size=int(len(last_idx) * 0.65), replace=False).tolist())
        attempts = [a for i, a in enumerate(attempts) if i not in drop]        # late / partial feed
        keep_last = [a for a in attempts if a[2].startswith(last)]
        attempts.extend(keep_last[:150])                                        # duplicated rows
        last_parcels = [p for p in parcels if p[1].startswith(last)]
        for p in last_parcels[:40]:
            p[3] = ""                                                           # missing dest hub
        print("!! --bad-data: dropped 65% of last-day attempts, added 150 duplicates, blanked 40 dest hubs")

    def write(name, header, rows):
        with open(os.path.join(args.out, name), "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(header)
            w.writerows(rows)

    write("hubs.csv", ["hub_code", "hub_name", "region"], HUBS)
    write("lanes.csv", ["lane", "origin_hub", "dest_hub", "sla_days"],
          [[l[0], l[1], l[2], l[3]] for l in LANES])
    write("parcels.csv", ["parcel_id", "created_at", "origin_hub", "dest_hub", "lane", "sla_days",
                          "origin_in_at", "origin_out_at", "dest_in_at", "dest_out_at",
                          "final_status", "delivered_at", "attempt_count"], parcels)
    write("attempts.csv", ["parcel_id", "attempt_no", "attempt_at", "outcome", "fail_reason",
                           "lane", "dest_hub"], attempts)
    print(f"Wrote {len(parcels):,} parcels and {len(attempts):,} attempts, {start} -> {end}, to {os.path.abspath(args.out)}")


if __name__ == "__main__":
    main()
