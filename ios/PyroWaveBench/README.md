# PyroWave on the connected iPad

This is a standalone, synthetic-only feasibility probe. EternalMonitor now
has an opt-in USB PyroWave path; see `../../docs/HANDOFF_PYROWAVE.md`.
No screen capture, accounts or
automatic diagnostics are used by this app.

## Windows / xtool

With the existing xtool WSL toolchain and the paired USB iPad:

```powershell
wsl -d Ubuntu-24.04 -u dev -- bash -lc 'cd /mnt/d/lab/EternalMonitor/ios/PyroWaveBench && xtool dev run -c release --usb'
python scripts/pyrowave_probe.py suite --output build/pyrowave/ipad-results.json
```

Keep the iPad unlocked and the benchmark in the foreground. The app uses a
separate bundle ID, `dev.eternalmonitor.PyroWaveBench` (xtool adds its team
prefix). It does not replace the installed EternalMonitor app. Only one
connected USB device is selected automatically; use `--device-id` for more.

The Apple device service on the PC must listen on loopback port 27015. The
probe connects through it to a **loopback-only** TCP listener on the iPad's
port 9878. There is no Internet server, upload destination or LAN listener.

## What it measures

- Real PC → iPad throughput through usbmux, using 16 MiB transfers with both
  64 KiB writes and writes the size of the current 1,402-byte EMLINK records.
- Synthetic SDR 4:2:0 Metal encode → packetize → parse → GPU decode at
  1920×1080/60, 1920×1080/120 and A2759-native 2388×1668/120.
- GPU decode time separately from CPU parsing and parse/submit/completion
  wall time; p50/p95/p99/max after 15 warmup frames.
- Cold pipeline setup, actual payload rate, start/end thermal state and an
  untimed decoded-luma readback compared to the input (mean absolute error).

The rate targets use upstream's *subjective* SDR bitrate heuristic:
`125 * (pixels / (1280 * 720))^0.38 * fps / 60` Mbps. These are useful starting
points, not a guarantee of game-image quality. A smooth synthetic pattern may
use less than the maximum. The wire-time estimate uses the configured target
and measured throughput, not the smaller synthetic payload.

## Limits and acceptance

The code is tested on the actual device, not inferred from a generic M2
benchmark. The native code compiles through SwiftPM/xtool; shader sources are
embedded and compiled at runtime, so no macOS Metal compiler is required.

The standalone suite alone does **not** establish Vulkan ↔ Metal interoperability, game-image
quality, Windows encoding time, screen capture, presentation timing or long
term thermal behavior. Metal encoding occurs before each decode; this warms
GPU caches and is not a sustained decoder-only streaming workload. The bulk
transfer test does not execute the production media assembler. USB wire time
and GPU time alone are not glass-to-glass latency.

The `validate --fixture` command additionally decodes a Windows-generated
EPW1 fixture and checks the production NV12 output. The handoff records the
completed interoperability and live-stream checks. Further optimization must
still verify the following:

1. Decode p95 remains comfortably below the 8.33 ms period at 120 Hz, with
   room for rendering, and decoded pixels match the synthetic image.
2. Measured USB throughput exceeds the target bitrate plus framing, audio,
   input and scheduling headroom. A USB-C or Thunderbolt port's label does
   not establish the performance of the Apple usbmux software path.
3. Windows-generated PyroWave packets decode correctly on Metal and look
   acceptable on real game content.
4. Capture-to-present p95 and game frame times beat the existing low latency
   H.264/HEVC path over a sustained run.

Upstream sources and license are recorded in `vendor/UPSTREAM.md` and
`vendor/LICENSE`. Do not modify the vendor files silently.
