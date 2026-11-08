#!/usr/bin/env python3
"""Measure the paired iPad's PyroWave decoder and the actual usbmux transport.

Run the ios/PyroWaveBench xtool app first. Uses only Python's standard library;
all traffic is synthetic and travels through the local Apple device service.
"""
import argparse
import json
import math
import pathlib
import plistlib
import socket
import struct
import time


def read_exact(stream, count):
    data = bytearray()
    while len(data) < count:
        chunk = stream.recv(count - len(data))
        if not chunk:
            raise ConnectionError("USB connection closed before the message completed")
        data.extend(chunk)
    return bytes(data)


def mux_request(stream, body):
    payload = plistlib.dumps({"ClientVersionString": "EternalMonitor-PyroWaveProbe",
                             "ProgName": "PyroWaveProbe", "kLibUSBMuxVersion": 3, **body})
    stream.sendall(struct.pack("<IIII", len(payload) + 16, 1, 8, 1) + payload)
    length, version, kind, tag = struct.unpack("<IIII", read_exact(stream, 16))
    if not 16 <= length <= 1024 * 1024 or (version, kind, tag) != (1, 8, 1):
        raise ValueError("Malformed usbmux response")
    return plistlib.loads(read_exact(stream, length - 16))


def device_id(address):
    with socket.create_connection(address, timeout=10) as stream:
        response = mux_request(stream, {"MessageType": "ListDevices"})
    devices = [item["DeviceID"] for item in response.get("DeviceList", [])
               if item.get("Properties", {}).get("ConnectionType") == "USB"]
    if len(devices) != 1:
        raise RuntimeError(f"Expected one USB iPad, found {len(devices)}; use --device-id")
    return devices[0]


def connect(address, device, port):
    stream = socket.create_connection(address, timeout=15)
    try:
        response = mux_request(stream, {"MessageType": "Connect", "DeviceID": device,
                                        "PortNumber": socket.htons(port)})
        if response.get("Number") != 0:
            raise ConnectionError(f"iPad benchmark port is unavailable: usbmux result {response.get('Number')}")
        return stream
    except BaseException:
        stream.close()
        raise


def response_json(stream):
    output = bytearray()
    while chunk := stream.recv(65536):
        output.extend(chunk)
        if len(output) > 4 * 1024 * 1024:
            raise ValueError("Benchmark response exceeds 4 MiB")
    result = json.loads(output)
    if "error" in result:
        raise RuntimeError(result["error"])
    return result


def command(address, device, port, text):
    with connect(address, device, port) as stream:
        stream.sendall(text.encode("ascii") + b"\n")
        return response_json(stream)


def throughput(address, device, port, size, chunk_size):
    with connect(address, device, port) as stream:
        stream.sendall(f"SINK {size}\n".encode())
        if read_exact(stream, 6) != b"READY\n":
            raise ValueError("Missing iPad throughput acknowledgement")
        chunk = bytes((i * 73 + 19) % 256 for i in range(chunk_size))
        start = time.perf_counter()
        remaining = size
        while remaining:
            count = min(remaining, len(chunk))
            stream.sendall(chunk[:count])
            remaining -= count
        ack = response_json(stream)
        seconds = time.perf_counter() - start
        if ack.get("bytes") != size:
            raise ValueError("iPad byte count did not match the data sent")
        return {"bytes": size, "write_chunk_bytes": chunk_size, "seconds": seconds,
                "host_to_ipad_mbps": size * 8 / seconds / 1_000_000, **ack}


def estimated_rate(width, height, fps, chroma444=False):
    """Upstream's subjective SDR baseline; an estimate, not a quality guarantee."""
    return 125 * ((width * height) / (1280 * 720)) ** 0.38 * fps / 60 * (1.15 if chroma444 else 1)


def serialization_ms(payload_mbps, fps, measured_mbps):
    if fps <= 0 or measured_mbps <= 0 or payload_mbps <= 0:
        raise ValueError("Rates must be positive")
    frame_bytes = payload_mbps * 1_000_000 / 8 / fps
    # Current EMLINK: a 2-byte length and a 32-byte media header per datagram.
    fragments = math.ceil(frame_bytes / 1368)
    return (frame_bytes + fragments * 34) * 8 / measured_mbps / 1000


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["status", "throughput", "suite", "validate"])
    parser.add_argument("--fixture", type=pathlib.Path)
    parser.add_argument("--mux-host", default="127.0.0.1")
    parser.add_argument("--mux-port", type=int, default=27015)
    parser.add_argument("--device-id", type=int)
    parser.add_argument("--port", type=int, default=9878)
    parser.add_argument("--frames", type=int, default=300, choices=range(30, 1001), metavar="30..1000")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args(argv)
    address = args.mux_host, args.mux_port
    device = args.device_id if args.device_id is not None else device_id(address)
    report = {"schema": 1, "transport": "paired Apple USB mux", "synthetic_only": True}
    if args.action == "validate":
        if args.fixture is None:
            parser.error("validate requires --fixture")
        data = args.fixture.read_bytes()
        if not 20 <= len(data) <= 4 * 1024 * 1024:
            parser.error("fixture must be between 20 bytes and 4 MiB")
        with connect(address, device, args.port) as stream:
            stream.sendall(f"VALIDATE {len(data)}\n".encode())
            if read_exact(stream, 6) != b"READY\n":
                raise ValueError("Missing fixture acknowledgement")
            stream.sendall(data)
            report.update(response_json(stream))
        if not report.get("pattern_check_passed"):
            raise RuntimeError(f"Vulkan/Metal fixture failed pixel validation: {report}")
    elif args.action == "status":
        report.update(command(address, device, args.port, "STATUS"))
    else:
        samples = [throughput(address, device, args.port, 16 * 1024 * 1024, chunk)
                   for chunk in [64 * 1024, 1402, 64 * 1024]]
        report["usb_throughput"] = samples
        if args.action == "suite":
            baseline = command(address, device, args.port, "STATUS")
            report["decode"] = []
            for width, height, fps in [(1920, 1080, 60), (1920, 1080, 120), (2388, 1668, 120)]:
                mbps = math.ceil(estimated_rate(width, height, fps))
                previous = len(baseline["results"])
                accepted = command(address, device, args.port,
                                   f"RUN {width} {height} {fps} {args.frames} {mbps}")
                if not accepted.get("accepted"):
                    raise RuntimeError("Another iPad benchmark is running")
                deadline = time.monotonic() + 180
                while True:
                    time.sleep(0.5)
                    baseline = command(address, device, args.port, "STATUS")
                    if len(baseline["results"]) > previous:
                        result = baseline["results"][-1]
                        if "error" in result:
                            raise RuntimeError(result["error"])
                        report["decode"].append(result)
                        break
                    if time.monotonic() > deadline:
                        raise TimeoutError("iPad benchmark did not complete within 180 seconds")
            # Use the lower bulk/framed measurement, rather than the USB port's advertised speed.
            measured = min(sample["host_to_ipad_mbps"] for sample in samples)
            for result in report["decode"]:
                network = serialization_ms(result["target_mbps"], result["fps_target"], measured)
                result["estimated_current_framing_wire_ms"] = network
                result["frame_period_ms"] = 1000 / result["fps_target"]
                result["estimated_wire_plus_decode_p95_ms"] = network + result["decode_parse_submit_wait"]["p95_ms"]
            report["limits"] = "Excludes PC capture/encode, display rendering/scanout and sustained thermal testing; Metal self-round-trip is not Vulkan interoperability validation."
    rendered = json.dumps(report, indent=2, ensure_ascii=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
