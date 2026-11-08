import io
import json
import math
import pathlib
import plistlib
import struct
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from pyrowave_probe import estimated_rate, mux_request, read_exact, response_json, serialization_ms


class FragmentedSocket:
    def __init__(self, data, fragment=3):
        self.source = io.BytesIO(data)
        self.fragment = fragment
        self.sent = b""

    def recv(self, count):
        return self.source.read(min(count, self.fragment))

    def sendall(self, data):
        self.sent += data


class USBProbeTests(unittest.TestCase):
    def test_plist_handshake_survives_fragmentation(self):
        payload = plistlib.dumps({"Number": 0})
        stream = FragmentedSocket(struct.pack("<IIII", len(payload) + 16, 1, 8, 1) + payload)
        self.assertEqual(mux_request(stream, {"MessageType": "ListDevices"}), {"Number": 0})
        length, version, kind, tag = struct.unpack("<IIII", stream.sent[:16])
        self.assertEqual((length, version, kind, tag), (len(stream.sent), 1, 8, 1))
        self.assertEqual(plistlib.loads(stream.sent[16:])["MessageType"], "ListDevices")

    def test_truncated_usb_message_fails(self):
        with self.assertRaises(ConnectionError):
            read_exact(FragmentedSocket(b"short"), 16)

    def test_unbounded_and_wrong_protocol_headers_are_rejected(self):
        for length, version, kind, tag in [(15, 1, 8, 1), (2**32-1, 1, 8, 1), (16, 0, 8, 1), (16, 1, 8, 9)]:
            stream = FragmentedSocket(struct.pack("<IIII", length, version, kind, tag))
            with self.assertRaises(ValueError):
                mux_request(stream, {"MessageType": "ListDevices"})

    def test_fragmented_benchmark_response_and_device_error(self):
        self.assertEqual(response_json(FragmentedSocket(b'{"state":"ready"}')), {"state": "ready"})
        with self.assertRaisesRegex(RuntimeError, "GPU failed"):
            response_json(FragmentedSocket(json.dumps({"error": "GPU failed"}).encode()))

    def test_rate_scales_with_fps_and_matches_upstream_1080p_baseline(self):
        rate = estimated_rate(1920, 1080, 60)
        self.assertAlmostEqual(rate, 170.114, places=3)
        self.assertEqual(estimated_rate(1920, 1080, 120), 2 * rate)
        self.assertAlmostEqual(estimated_rate(1920, 1080, 60, True), rate * 1.15)

    def test_usb_framing_and_insufficient_bandwidth(self):
        # 120 Mbps / 120 fps = 125,000 payload bytes/frame, plus 92 record headers.
        expected = (125000 + math.ceil(125000 / 1368) * 34) * 8 / 250000000 * 1000
        self.assertAlmostEqual(serialization_ms(120, 120, 250), expected)
        self.assertGreater(serialization_ms(341, 120, 253), 1000 / 120)
        self.assertLess(serialization_ms(171, 60, 253), 1000 / 60)

    def test_zero_or_negative_rates_are_rejected(self):
        for rates in [(0, 120, 253), (200, 0, 253), (200, 120, 0), (200, 120, -1)]:
            with self.assertRaises(ValueError):
                serialization_ms(*rates)


if __name__ == "__main__":
    unittest.main()
