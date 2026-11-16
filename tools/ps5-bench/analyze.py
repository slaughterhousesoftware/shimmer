#!/usr/bin/env python3
"""Summarise one Shimmer telemetry frames file (per-frame NDJSON) as JSON.

Usage: analyze.py <telemetry-frames-*.ndjson>
Skips the first 5 s (connect, window animation)."""
import json
import sys


def q(values, p):
    v = sorted(values)
    return round(v[min(len(v) - 1, int(len(v) * p))], 2) if v else None


frames = [json.loads(line) for line in open(sys.argv[1]) if "t_present_ms" in line]
t0 = frames[0]["t_present_ms"] if frames else 0
frames = [f for f in frames if f["t_present_ms"] - t0 >= 5000]
times = [f["t_present_ms"] for f in frames]
gaps = [b - a for a, b in zip(times, times[1:])]
e2e = [f["end_to_end_ms"] for f in frames if "end_to_end_ms" in f]
print(json.dumps({
    "frames": len(frames),
    "e2e_p50_ms": q(e2e, 0.5), "e2e_p99_ms": q(e2e, 0.99),
    "gap_max_ms": round(max(gaps), 1) if gaps else None,
    "gaps_over_33ms": sum(1 for g in gaps if g > 33.4),
    "off_cadence_pct": round(100 * sum(1 for g in gaps if g < 12.5 or g > 20.8) / max(1, len(gaps)), 1),
}))
