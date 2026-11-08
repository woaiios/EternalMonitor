import unittest

from scripts.analyze_frame_trace import analyze


class FrameTraceTest(unittest.TestCase):
    def test_joins_one_frame_and_clock_domains(self):
        host = """INFO Frame trace capture capture_us=3000 readback_done_us=4000
INFO Frame trace encode capture_us=3000 encode_done_us=8000 encode_us=3000 convert_us=1000
INFO Frame trace send capture_us=3000 frame_seq=7 stream_epoch=2 send_done_us=9000 send_failed=false
INFO Frame trace USB write capture_us=3000 frame_seq=7 stream_epoch=2 usb_write_start_us=10000 usb_write_done_us=12000"""
        client = """event=receive_first capture_us=3000 client_us=10500 epoch=2 seq=7
event=assembled capture_us=3000 client_us=12500 seq=7 offset_us=0 rtt_us=500
event=decode_start capture_us=3000 client_us=13000
event=decode_end capture_us=3000 client_us=15000 seq=7 epoch=2
event=render_submit capture_us=3000 client_us=16000
event=presented capture_us=3000 client_us=21000 presented_seconds=0.020 callback_media_seconds=0.021"""
        result = analyze(host, client)
        self.assertEqual(result["complete_frames"], 1)
        self.assertEqual(result["stages"]["capture_to_presented_estimate"]["p50_ms"], 17)
        self.assertEqual(result["stages"]["usb_write"]["p50_ms"], 2)
        groups = result["critical_path_groups"]
        self.assertEqual(sum(g["mean_ms"] for g in groups.values()), 17)
        self.assertEqual(result["coverage"]["presented"], 1)
        self.assertEqual(analyze(host, client.replace("seq=7 epoch=2", "seq=8 epoch=2"))["complete_frames"], 0)
        self.assertEqual(analyze(host, client, epoch=3)["complete_frames"], 0)
        self.assertEqual(analyze(host, client, minimum_capture_us=4000)["complete_frames"], 0)
        self.assertEqual(analyze(host, client.replace("presented_seconds=0.020", "presented_seconds=0"))["complete_frames"], 0)
        self.assertEqual(analyze(host, client.replace("seq=7 offset_us", "seq=8 offset_us"))["complete_frames"], 0)
        gpu_client = client + "\nevent=render_gpu_done capture_us=3000 client_us=18000 gpu_start_seconds=0.0165 gpu_end_seconds=0.017 callback_media_seconds=0.018"
        gpu_result = analyze(host, gpu_client)
        self.assertEqual(gpu_result["stages"]["render_gpu"]["p50_ms"], .5)
        self.assertEqual(gpu_result["stages"]["render_gpu_end_to_presented_estimate"]["p50_ms"], 3)

    def test_incomplete_samples_do_not_look_like_zero_latency(self):
        result = analyze("INFO Frame trace capture capture_us=3000 readback_done_us=4000", "")
        self.assertEqual(result["complete_frames"], 0)
        self.assertEqual(result["coverage"], {"capture": 1})
        self.assertIsNone(result["stages"]["capture_to_presented_estimate"])


if __name__ == "__main__":
    unittest.main()
