"""Join opt-in EternalMonitor frame traces by host capture timestamp.

Host times are process-monotonic; client times are iPad uptime. The clock
offset comes from the protocol's four-timestamp estimator (host minus client).
USB writes are writes to the host's tunnel, not physical wire timestamps.
"""
import argparse
import json
import math
import re
from collections import defaultdict
from pathlib import Path


def fields(line):
    return dict(re.findall(r"(\w+)=([^\s]+)", line))


def summarize(values):
    values = sorted(values)
    if not values:
        return None
    def percentile(p):
        return round(values[min(len(values) - 1, math.ceil(p * len(values)) - 1)], 3)
    return {"n": len(values), "p50_ms": percentile(.5), "p95_ms": percentile(.95),
            "min_ms": round(values[0], 3), "max_ms": round(values[-1], 3)}


def analyze(host_text, client_text, *, epoch=None, minimum_capture_us=0):
    frames = defaultdict(dict)
    for line in host_text.splitlines():
        if "Frame trace " not in line:
            continue
        d = fields(line)
        event = line.split("Frame trace ", 1)[1].split()[0]
        if d.get("capture_us", "").isdigit():
            frames[int(d["capture_us"])][event] = d
    for line in client_text.splitlines():
        d = fields(line)
        if d.get("capture_us", "").isdigit() and d.get("event"):
            frames[int(d["capture_us"])].setdefault(d["event"], d)
    metrics = defaultdict(list)
    groups = defaultdict(list)
    coverage = defaultdict(int)
    rows = []
    complete = []
    for capture, f in frames.items():
        if capture < minimum_capture_us:
            continue
        identity = f.get("send", f.get("receive_first", {}))
        frame_epoch = identity.get("stream_epoch", identity.get("epoch"))
        if epoch is not None and frame_epoch != str(epoch):
            continue
        for event in f:
            coverage[event] += 1
        required = ("capture", "encode", "send", "USB", "receive_first", "assembled",
                    "decode_start", "decode_end", "render_submit", "presented")
        if not all(k in f for k in required) or f["assembled"].get("offset_us") in (None, "unknown"):
            continue
        if f["send"].get("send_failed") != "false":
            continue
        if (f["send"].get("stream_epoch") != f["receive_first"].get("epoch") or
                f["send"].get("frame_seq") != f["receive_first"].get("seq") or
                f["send"].get("frame_seq") != f["decode_end"].get("seq")):
            continue
        # Reject mixed frames even when their capture timestamps collide.
        seq = f["send"]["frame_seq"]
        frame_epoch = f["send"]["stream_epoch"]
        if any(d.get("seq", d.get("frame_seq", seq)) != seq or
               d.get("epoch", d.get("stream_epoch", frame_epoch)) != frame_epoch
               for d in f.values()):
            continue
        try:
            h = lambda e, k: int(f[e][k])
            c = lambda e: h(e, "client_us")
            offset = int(f["assembled"]["offset_us"])
            if float(f["presented"]["presented_seconds"]) <= 0:
                continue
            present = c("presented") - round((float(f["presented"]["callback_media_seconds"]) -
                                                float(f["presented"]["presented_seconds"])) * 1e6)
            readback = h("capture", "readback_done_us")
            encode_end = h("encode", "encode_done_us")
            encode_duration = h("encode", "encode_us")
            encode_start = encode_end - encode_duration
            convert = h("encode", "convert_us")
            enqueue_end = h("send", "send_done_us")
            write_start = h("USB", "usb_write_start_us")
            write_end = h("USB", "usb_write_done_us")
            stages = {
                "capture_to_readback": readback - capture,
                "readback_to_encode_start": encode_start - readback,
                "cpu_convert": convert,
                "encode_total": encode_duration,
                "encode_after_convert": encode_duration - convert,
                "encode_end_to_enqueued": enqueue_end - encode_end,
                "enqueued_to_usb_write_start": write_start - enqueue_end,
                "usb_write": write_end - write_start,
                "first_receive_to_assembled": c("assembled") - c("receive_first"),
                "usb_write_end_to_assembled_estimate": c("assembled") + offset - write_end,
                "assembly_to_decode_start": c("decode_start") - c("assembled"),
                "decode": c("decode_end") - c("decode_start"),
                "decode_end_to_render_submit": c("render_submit") - c("decode_end"),
                "render_submit_to_presented": present - c("render_submit"),
                "capture_to_presented_estimate": present + offset - capture,
                "capture_to_decode_submit_estimate": c("decode_end") + offset - capture,
                "clock_rtt": int(f["assembled"]["rtt_us"]),
            }
        except (KeyError, ValueError, OverflowError):
            continue
        if min(stages.values()) < -2000:
            continue
        for name, value in stages.items():
            metrics[name].append(value / 1000)
        if "decode_gpu_done" in f:
            try:
                gpu = f["decode_gpu_done"]
                start_s, end_s = float(gpu["gpu_start_seconds"]), float(gpu["gpu_end_seconds"])
                if 0 < start_s <= end_s:
                    end_client = c("decode_gpu_done") - round((float(gpu["callback_media_seconds"]) - end_s) * 1e6)
                    metrics["decode_gpu"].append((end_s - start_s) * 1000)
                    metrics["capture_to_decode_gpu_complete_estimate"].append((end_client + offset - capture) / 1000)
            except (KeyError, ValueError, OverflowError):
                pass
        if "render_gpu_done" in f:
            try:
                gpu = f["render_gpu_done"]
                start_s, end_s = float(gpu["gpu_start_seconds"]), float(gpu["gpu_end_seconds"])
                callback_s = float(gpu["callback_media_seconds"])
                gpu_start = c("render_gpu_done") - round((callback_s - start_s) * 1e6)
                gpu_end = c("render_gpu_done") - round((callback_s - end_s) * 1e6)
                if 0 < start_s <= end_s and gpu_start >= c("render_submit") - 2000 and present >= gpu_end - 2000:
                    metrics["render_submit_to_gpu_start_estimate"].append((gpu_start - c("render_submit")) / 1000)
                    metrics["render_gpu"].append((end_s - start_s) * 1000)
                    metrics["render_gpu_end_to_presented_estimate"].append((present - gpu_end) / 1000)
            except (KeyError, ValueError, OverflowError):
                pass
        # These four intervals partition the same frame's critical path.
        # USB write and first-receive-to-assembly overlap, so never add them.
        partition = {
            "host_capture_to_encode_end": encode_end - capture,
            "transport_encode_end_to_assembled": c("assembled") + offset - encode_end,
            "client_assembled_to_decode_end": c("decode_end") - c("assembled"),
            "client_decode_end_to_presented": present - c("decode_end"),
        }
        for name, value in partition.items():
            groups[name].append(value / 1000)
        rows.append({"capture_us": capture, "epoch": int(frame_epoch), "seq": int(seq),
                     **{k: v / 1000 for k, v in partition.items()},
                     "capture_to_presented_estimate": stages["capture_to_presented_estimate"] / 1000})
        complete.append(capture)
    total = sum(metrics["capture_to_presented_estimate"])
    slow = sorted(rows, key=lambda row: row["capture_to_presented_estimate"])[-max(1, math.ceil(len(rows) * .1)):]
    return {"complete_frames": len(complete), "coverage": dict(coverage),
            "stages": {k: summarize(v) for k, v in metrics.items()},
            "critical_path_groups": {k: {**summarize(v), "mean_ms": round(sum(v) / len(v), 3),
                "share_of_mean_percent": round(sum(v) / total * 100, 1) if total else None,
                "slowest_decile_mean_ms": round(sum(r[k] for r in slow) / len(slow), 3)}
                for k, v in groups.items()},
            "notes": ["Per-stage percentiles are independent and cannot be added.",
                      "Only matched, presented sampled frames contribute; coverage exposes selection bias.",
                      "First receive to assembled overlaps USB write; critical_path_groups do not overlap.",
                      "Cross-device estimates depend on clock synchronization.",
                      "USB write timestamps measure OS tunnel writes, not physical bus events.",
                      "Presented time is the display-server presentation event, not panel response."]}


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("host", type=Path)
    p.add_argument("client", type=Path)
    p.add_argument("--output", type=Path)
    p.add_argument("--epoch", type=int, help="Restrict to one stream generation")
    p.add_argument("--warmup-seconds", type=float, default=0,
                   help="Ignore capture timestamps before this host-process age")
    args = p.parse_args()
    result = analyze(args.host.read_text(encoding="utf-8", errors="replace"),
                     args.client.read_text(encoding="utf-8", errors="replace"), epoch=args.epoch,
                     minimum_capture_us=int(args.warmup_seconds * 1e6))
    text = json.dumps(result, indent=2, ensure_ascii=False)
    if args.output:
        args.output.write_text(text + "\n", encoding="utf-8")
    print(text)
