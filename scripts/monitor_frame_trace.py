"""Collect bounded, local-only latency snapshots from an already tracing stream.

Enable ETERNAL_FRAME_TRACE=1 on the host and launch the iPad app with
--frame-trace first. This command does not restart apps or change streaming.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

from analyze_frame_trace import analyze, fields


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=float, default=60)
    parser.add_argument("--interval", type=float, default=15)
    parser.add_argument("--warmup-seconds", type=float, default=15)
    parser.add_argument("--epoch", type=int)
    parser.add_argument("--output", type=Path, default=Path("build/pyrowave/latency-monitor"))
    parser.add_argument("--app", default="XTL-UH6S3NYDHH.dev.eternalmonitor.PyroWavePreview")
    parser.add_argument("--ios", type=Path, default=Path(os.environ["APPDATA"]) / "npm/ios.exe")
    parser.add_argument("--host-log", type=Path,
                        default=Path(os.environ["APPDATA"]) / "EternalMonitor/logs/eternal-host-session.log")
    args = parser.parse_args()
    if not (0 <= args.duration <= 3600 and 1 <= args.interval <= 60 and args.warmup_seconds >= 0):
        parser.error("duration must be 0..3600, interval 1..60, and warmup nonnegative")
    args.output.mkdir(parents=True, exist_ok=True)
    destination = args.output.resolve()
    initial = args.host_log.read_text(encoding="utf-8", errors="replace")
    capture_floor = max((int(d["capture_us"]) for line in initial.splitlines()
                         if "Frame trace " in line and (d := fields(line)).get("capture_us", "").isdigit()), default=0)
    capture_floor = max(capture_floor, int(args.warmup_seconds * 1e6))
    started = time.monotonic()
    index = 0
    while True:
        # Pull only our timing log, never screenshots or the whole app container.
        client = destination / f"ipad-{index:03d}.log"
        for attempt in range(3):
            try:
                subprocess.run([str(args.ios), "file", "pull", f"--app={args.app}",
                                "--remote=Documents/frame-trace.log", f"--local={client}",
                                "--tunnel-info-port=28100"], cwd=destination,
                               check=True, capture_output=True, timeout=20)
                break
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                if attempt == 2:
                    detail = getattr(error, "stderr", b"") or b""
                    raise RuntimeError("Timing-log download failed after three attempts: " +
                                       detail.decode("utf-8", errors="replace")) from error
                time.sleep(.3)
        host_text = args.host_log.read_text(encoding="utf-8", errors="replace")
        (destination / f"host-{index:03d}.log").write_text(host_text, encoding="utf-8")
        latest_epoch = args.epoch
        if latest_epoch is None:
            latest_epoch = max((int(d["stream_epoch"]) for line in host_text.splitlines()
                                if "Frame trace send" in line and (d := fields(line)).get("stream_epoch", "").isdigit()), default=None)
        report = analyze(host_text, client.read_text(encoding="utf-8", errors="replace"),
                         epoch=latest_epoch, minimum_capture_us=capture_floor)
        report["stream_epoch"] = latest_epoch
        report["minimum_capture_us"] = capture_floor
        report["elapsed_seconds"] = round(time.monotonic() - started, 1)
        rendered = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
        (destination / f"report-{index:03d}.json").write_text(rendered, encoding="utf-8")
        (destination / "latest.json").write_text(rendered, encoding="utf-8")
        end_to_end = report["stages"].get("capture_to_presented_estimate")
        print(json.dumps({"elapsed_seconds": report["elapsed_seconds"],
                          "matched_presented_frames": report["complete_frames"],
                          "capture_to_presented_estimate": end_to_end}), flush=True)
        remaining = args.duration - (time.monotonic() - started)
        if remaining <= 0:
            if report["complete_frames"] == 0:
                raise RuntimeError("No matched presented frames; check tracing flags, app state and clock sync")
            return
        time.sleep(min(args.interval, remaining))
        index += 1


if __name__ == "__main__":
    main()
