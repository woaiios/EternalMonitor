"""Small ctypes bridge for testing the pinned Windows PyroWave Vulkan C API.

This is an interoperability probe, not the production capture/encode stage.
Loads only the DLL explicitly named by the caller. No downloads or DLL search.
"""
import argparse
import ctypes as c
import json
import os
import pathlib
import struct
import time


class EncoderInfo(c.Structure):
    _fields_ = [("device", c.c_void_p), ("width", c.c_int), ("height", c.c_int), ("chroma", c.c_int)]


class CPUBuffer(c.Structure):
    _fields_ = [("data", c.c_void_p * 3), ("stride", c.c_size_t * 3), ("size", c.c_size_t * 3),
                ("width", c.c_int), ("height", c.c_int), ("format", c.c_int)]


class Packet(c.Structure):
    _fields_ = [("offset", c.c_size_t), ("size", c.c_size_t)]


class Rate(c.Structure):
    _fields_ = [("maximum_bitstream_size", c.c_size_t)]


def load(path):
    library = c.CDLL(str(path.resolve()))
    signatures = {
        "pyrowave_get_api_version": (None, [c.POINTER(c.c_uint32)] * 3),
        "pyrowave_create_default_device": (c.c_int, [c.POINTER(c.c_void_p)]),
        "pyrowave_device_destroy": (None, [c.c_void_p]),
        "pyrowave_create_device_by_compat": (c.c_int, [c.c_uint32, c.c_uint32, c.c_void_p, c.c_void_p, c.c_void_p, c.c_int, c.POINTER(c.c_void_p)]),
        "pyrowave_device_get_vk_device_handles": (None, [c.c_void_p, c.POINTER(c.c_void_p), c.POINTER(c.c_void_p), c.POINTER(c.c_void_p)]),
        "pyrowave_device_set_queue_type": (c.c_int, [c.c_void_p, c.c_int]),
        "pyrowave_encoder_create": (c.c_int, [c.POINTER(EncoderInfo), c.POINTER(c.c_void_p)]),
        "pyrowave_encoder_destroy": (None, [c.c_void_p]),
        "pyrowave_encoder_encode_cpu": (c.c_int, [c.c_void_p, c.POINTER(CPUBuffer), c.POINTER(Rate)]),
        "pyrowave_encoder_compute_num_packets": (c.c_int, [c.c_void_p, c.c_size_t, c.POINTER(c.c_size_t)]),
        "pyrowave_encoder_packetize": (c.c_int, [c.c_void_p, c.POINTER(Packet), c.c_size_t, c.POINTER(c.c_size_t), c.c_void_p, c.c_size_t]),
    }
    for name, (result, args) in signatures.items():
        function = getattr(library, name)
        function.restype, function.argtypes = result, args
    major, minor, patch = c.c_uint32(), c.c_uint32(), c.c_uint32()
    library.pyrowave_get_api_version(c.byref(major), c.byref(minor), c.byref(patch))
    if major.value != 1:
        raise RuntimeError(f"Unsupported PyroWave API major {major.value}")
    return library


def checked(code, operation):
    if code != 0:
        raise RuntimeError(f"PyroWave {operation} failed: {code}")


def fixture(library, width, height, fps, mbps, frames=120, vendor=0):
    if width < 64 or height < 64 or width > 4096 or height > 4096 or width % 2 or height % 2:
        raise ValueError("Expected even dimensions between 64 and 4096")
    if not 30 <= fps <= 120 or not 50 <= mbps <= 1000 or not 1 <= frames <= 1000:
        raise ValueError("Invalid rate or sample count")
    planes = [bytes(32 + ((x // 4 + y // 4) % 160) + (((x // 32) ^ (y // 32)) & 1) * 32
                    for y in range(height) for x in range(width)),
              bytes([112]) * (width * height // 4), bytes([144]) * (width * height // 4)]
    buffers = [c.create_string_buffer(plane) for plane in planes]
    image = CPUBuffer((c.c_void_p * 3)(*[c.addressof(buffer) for buffer in buffers]),
                      (c.c_size_t * 3)(width, width // 2, width // 2),
                      (c.c_size_t * 3)(*[len(plane) for plane in planes]), width, height, 1)
    rate = Rate(mbps * 1_000_000 // 8 // fps)
    output = c.create_string_buffer(rate.maximum_bitstream_size)
    device, encoder = c.c_void_p(), c.c_void_p()
    samples = []
    try:
        checked(library.pyrowave_create_device_by_compat(vendor, 0, None, None, None, 256, c.byref(device)), "device create")
        checked(library.pyrowave_device_set_queue_type(device, 2), "async compute queue selection")
        physical = c.c_void_p()
        library.pyrowave_device_get_vk_device_handles(device, None, c.byref(physical), None)
        vulkan = c.WinDLL(str(pathlib.Path(os.environ['SystemRoot']) / 'System32' / 'vulkan-1.dll'))
        vulkan.vkGetPhysicalDeviceProperties.argtypes = [c.c_void_p, c.c_void_p]
        vulkan.vkGetPhysicalDeviceProperties.restype = None
        properties = c.create_string_buffer(4096)
        vulkan.vkGetPhysicalDeviceProperties(physical, properties)
        gpu_name = properties.raw[20:276].split(b'\0')[0].decode('utf-8', errors='replace')
        checked(library.pyrowave_encoder_create(c.byref(EncoderInfo(device, width, height, 0)), c.byref(encoder)), "encoder create")
        for index in range(-15, frames):
            start = time.perf_counter()
            checked(library.pyrowave_encoder_encode_cpu(encoder, c.byref(image), c.byref(rate)), "encode")
            count = c.c_size_t()
            checked(library.pyrowave_encoder_compute_num_packets(encoder, len(output), c.byref(count)), "packet count")
            if not 1 <= count.value <= 4096:
                raise ValueError("Unreasonable packet count returned by codec")
            packets = (Packet * count.value)()
            checked(library.pyrowave_encoder_packetize(encoder, packets, len(output), c.byref(count), output, len(output)), "packetize")
            if index >= 0:
                samples.append((time.perf_counter() - start) * 1000)
        # Test envelope, little endian: EPW1, width/height, video-range 4:2:0 flag, packet count.
        body = bytearray(struct.pack("<4sHHII", b"EPW1", width, height, 1, count.value))
        for packet in packets[:count.value]:
            if packet.offset + packet.size > len(output):
                raise ValueError("Packet exceeds output allocation")
            body += struct.pack("<I", packet.size) + output.raw[packet.offset:packet.offset + packet.size]
        samples.sort()
        return bytes(body), {"gpu": gpu_name, "queue_preference": "async compute", "width": width, "height": height, "frames": frames, "fps": fps, "target_mbps": mbps,
                             "envelope_bytes": len(body), "encode_upload_and_packetize_p50_ms": samples[(len(samples)-1)//2],
                             "encode_upload_and_packetize_p95_ms": samples[min(len(samples)-1, int(len(samples)*0.95))],
                             "scope": "Synthetic CPU YUV upload + Vulkan encode + packetize; excludes DXGI capture and RGB conversion"}
    finally:
        if encoder.value:
            library.pyrowave_encoder_destroy(encoder)
        if device.value:
            library.pyrowave_device_destroy(device)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--width", type=int, default=1920)
    parser.add_argument("--height", type=int, default=1080)
    parser.add_argument("--fps", type=int, default=120)
    parser.add_argument("--mbps", type=int, default=341)
    parser.add_argument("--gpu-vendor", choices=["auto", "nvidia", "amd"], default="auto")
    args = parser.parse_args()
    data, report = fixture(load(args.dll), args.width, args.height, args.fps, args.mbps,
                           vendor={"auto": 0, "nvidia": 0x10de, "amd": 0x1002}[args.gpu_vendor])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    args.output.with_suffix(".json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
