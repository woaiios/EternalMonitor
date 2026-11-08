"""Run an already installed NativePresentBench; this replaces no app itself.

Read ios/NativePresentBench/README.md before installing the benchmark: it uses
the streaming preview's app ID. Reinstall the streaming app after testing.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

from analyze_native_present import analyze


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["cadirect", "calate", "metaldirect", "metallate"], required=True)
    parser.add_argument("--fps", type=int, choices=[60, 120], default=120)
    parser.add_argument("--drawables", type=int, choices=[2, 3], default=2)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--lead-us", type=int, default=2500)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 10 <= args.seconds <= 120:
        parser.error("seconds must be 10..120")
    args.output.mkdir(parents=True, exist_ok=True)
    ios = str(Path(os.environ["APPDATA"]) / "npm/ios.exe")
    app = "XTL-UH6S3NYDHH.dev.eternalmonitor.PyroWavePreview"
    def call(*command, check=True):
        result = subprocess.run([ios, *command, "--tunnel-info-port=28100"],
                                capture_output=True, timeout=25)
        with (args.output / "device-command.log").open("ab") as log:
            log.write(result.stdout + result.stderr)
        if check:
            result.check_returncode()
        return result
    call("kill", app, check=False)
    call("launch", app, f"--arg=--mode={args.mode}", f"--arg=--fps={args.fps}",
         f"--arg=--drawables={args.drawables}", f"--arg=--seconds={args.seconds}", f"--arg=--lead-us={args.lead_us}")
    print(f"Running local Metal: {args.mode}, {args.fps}fps, {args.drawables} drawables", flush=True)
    remaining = args.seconds + 3
    while remaining:
        delay = min(10, remaining)
        time.sleep(delay)
        remaining -= delay
    trace = (args.output / "trace.jsonl").resolve()
    for attempt in range(3):
        result = call("file", "pull", f"--app={app}", "--remote=Documents/native-present.jsonl",
                      f"--local={trace}", check=False)
        if result.returncode == 0 and trace.exists() and trace.stat().st_size:
            break
        if attempt == 2:
            raise RuntimeError("Could not read native benchmark log; see device-command.log")
        time.sleep(.5)
    report = analyze(trace)
    if (report["metadata"]["mode"] != args.mode or report["metadata"]["fps_requested"] != args.fps
            or report["metadata"].get("drawables") != args.drawables
            or report["metadata"].get("duration") != args.seconds
            or abs(report["metadata"].get("lead_us", -1) - args.lead_us) > .1
            or not report["finished"] or report["matched_presented_frames"] == 0):
        raise RuntimeError("Incomplete or unexpected benchmark run")
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"presented_fps": report["actual_presented_fps"],
        "interval": report["actual_present_interval"],
        "gpu_ready_wait": report["stages"]["gpu_end_to_presented"],
        "frames": report["matched_presented_frames"]}), flush=True)


if __name__ == "__main__":
    main()
