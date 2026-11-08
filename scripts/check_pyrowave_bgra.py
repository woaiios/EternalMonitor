"""GPU integration check: BGRA color bars -> PyroWave -> decoded BT.709 YUV.

Requires the explicitly supplied Windows DLL and a working Vulkan GPU.
"""
import argparse
import ctypes as c
import json
from pathlib import Path
from pyrowave_native import load, checked, EncoderInfo, CPUBuffer, Packet, Rate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", type=Path, required=True)
    parser.add_argument("--gpu", choices=["nvidia", "amd"], default="nvidia")
    args = parser.parse_args()
    api = load(args.dll)
    bgra = api.em_pyrowave_encoder_encode_bgra
    bgra.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_int, c.c_int, c.c_size_t, c.POINTER(Rate)]
    bgra.restype = c.c_int
    api.pyrowave_decoder_create.argtypes = [c.POINTER(EncoderInfo), c.POINTER(c.c_void_p)]
    api.pyrowave_decoder_create.restype = c.c_int
    api.pyrowave_decoder_push_packet.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t]
    api.pyrowave_decoder_push_packet.restype = c.c_int
    api.pyrowave_decoder_decode_cpu_buffer_synchronous.argtypes = [c.c_void_p, c.POINTER(CPUBuffer)]
    api.pyrowave_decoder_decode_cpu_buffer_synchronous.restype = c.c_int
    api.pyrowave_decoder_destroy.argtypes = [c.c_void_p]
    device = c.c_void_p()
    checked(api.pyrowave_create_device_by_compat(0x10de if args.gpu == "nvidia" else 0x1002,
        0, None, None, None, 256, c.byref(device)), "device create")
    checked(api.pyrowave_device_set_queue_type(device, 2), "queue selection")
    colors = [(0,0,0), (255,255,255), (255,0,0), (0,255,0), (0,0,255), (128,128,128), (0,255,255), (255,0,255)]
    width, height = 512, 256
    row = b"".join(bytes((b,g,r,255)) * (width // len(colors)) for r,g,b in colors)
    pixels = c.create_string_buffer(row * height)
    results = []
    try:
        for out_w, out_h in [(512,256), (256,128)]:
            encoder, decoder = c.c_void_p(), c.c_void_p()
            try:
                info = EncoderInfo(device, out_w, out_h, 0)
                checked(api.pyrowave_encoder_create(c.byref(info), c.byref(encoder)), "encoder create")
                checked(api.pyrowave_decoder_create(c.byref(info), c.byref(decoder)), "decoder create")
                rate = Rate(128 * 1024)
                checked(bgra(encoder, pixels, width*height*4, width, height, width*4, c.byref(rate)), "BGRA encode")
                count = c.c_size_t()
                checked(api.pyrowave_encoder_compute_num_packets(encoder, rate.maximum_bitstream_size, c.byref(count)), "packet count")
                assert 0 < count.value <= 4096
                packets = (Packet * count.value)()
                encoded = c.create_string_buffer(rate.maximum_bitstream_size)
                checked(api.pyrowave_encoder_packetize(encoder, packets, len(encoded), c.byref(count), encoded, len(encoded)), "packetize")
                for packet in packets[:count.value]:
                    checked(api.pyrowave_decoder_push_packet(decoder, c.byref(encoded, packet.offset), packet.size), "parse")
                sizes = [out_w*out_h, out_w*out_h//4, out_w*out_h//4]
                planes = [c.create_string_buffer(n) for n in sizes]
                target = CPUBuffer((c.c_void_p*3)(*[c.addressof(p) for p in planes]),
                    (c.c_size_t*3)(out_w,out_w//2,out_w//2), (c.c_size_t*3)(*sizes), out_w,out_h,1)
                checked(api.pyrowave_decoder_decode_cpu_buffer_synchronous(decoder,c.byref(target)), "decode readback")
                measured = [planes[0].raw[(out_h//2)*out_w + int((i+.5)*out_w/8)] for i in range(8)]
                expected = [round(16+219*(.2126*r+.7152*g+.0722*b)/255) for r,g,b in colors]
                error = max(abs(a-b) for a,b in zip(measured,expected))
                assert error <= 3, (measured, expected)
                results.append({"input":[width,height],"output":[out_w,out_h],"maximum_luma_error":error,
                                "luma":measured,"expected_bt709_video_range":expected})
            finally:
                if decoder: api.pyrowave_decoder_destroy(decoder)
                if encoder: api.pyrowave_encoder_destroy(encoder)
    finally:
        api.pyrowave_device_destroy(device)
    print(json.dumps({"gpu":args.gpu,"checks":results},indent=2))


if __name__ == "__main__":
    main()
