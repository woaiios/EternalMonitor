"""Analyze local native-present.jsonl without cross-device clock conversion."""
import argparse
import json
import math
from pathlib import Path


def stats(values):
    values = sorted(values)
    if not values:
        return None
    return {"n": len(values), "p50_ms": round(values[math.ceil(len(values) * .5) - 1], 4),
            "p95_ms": round(values[math.ceil(len(values) * .95) - 1], 4),
            "min_ms": round(values[0], 4), "max_ms": round(values[-1], 4)}


def analyze(path, warmup=5):
    events = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    meta = next(e for e in events if e["event"] == "metadata")
    end = next((e for e in events if e["event"] == "finished"), None)
    frames = {}
    for e in events:
        if "id" in e:
            frames.setdefault(e["id"], {})[e["event"]] = e
    selected = [f for f in frames.values() if "submit" in f and
                warmup <= f["submit"]["begin"] - meta["start"] < meta["duration"] - 1]
    valid = [f for f in selected if "gpu" in f and "presented" in f and
             f["gpu"]["status"] == 4 and 0 < f["gpu"]["start"] <= f["gpu"]["end"] and
             f["presented"]["time"] > 0 and f["presented"]["time"] >= f["gpu"]["end"] - .0001]
    metrics = {name: [] for name in ("gpu_render", "gpu_end_to_presented", "submit_to_presented",
        "render_begin_to_presented", "callback_to_presented", "drawable_acquire",
        "presented_minus_target", "submit_before_deadline", "presented_callback_lag")}
    for f in valid:
        s, g, p = f["submit"], f["gpu"], f["presented"]
        times = {"gpu_render": g["end"] - g["start"],
            "gpu_end_to_presented": p["time"] - g["end"],
            "submit_to_presented": p["time"] - s["submit_end"],
            "render_begin_to_presented": p["time"] - s["begin"],
            "callback_to_presented": p["time"] - s["callback"],
            "drawable_acquire": s["acquired"] - s["begin"],
            "presented_minus_target": p["time"] - s["target"],
            "submit_before_deadline": s["deadline"] - s["submit_end"],
            "presented_callback_lag": p["callback"] - p["time"]}
        for name, time in times.items():
            metrics[name].append(time * 1000)
    # Use every actual presented timestamp, even if its GPU sample is missing.
    presentations = sorted(f["presented"]["time"] for f in selected
                           if f.get("presented", {}).get("time", 0) > 0)
    intervals = [(b - a) * 1000 for a, b in zip(presentations, presentations[1:])]
    return {"metadata": meta, "finished": end, "warmup_seconds": warmup,
            "selected_submissions": len(selected), "matched_presented_frames": len(valid),
            "zero_presented": sum(f.get("presented", {}).get("time") == 0 for f in selected),
            "missing_presentation": sum("presented" not in f for f in selected),
            "stages": {k: stats(v) for k, v in metrics.items()},
            "actual_present_interval": stats(intervals),
            "actual_presented_fps": round((len(presentations) - 1) / (presentations[-1] - presentations[0]), 3)
                if len(presentations) > 1 and presentations[-1] > presentations[0] else None,
            "notes": ["Same-device GPU and drawable Mach timestamps; no network/decoder or clock sync.",
                      "System presentation event, not photodiode scanout/pixel-response measurement.",
                      "Refresh interval and GPU-ready-to-presentation delay are different measurements."]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = json.dumps(analyze(args.trace), indent=2, ensure_ascii=False) + "\n"
    if args.output:
        args.output.write_text(report, encoding="utf-8")
    print(report)
