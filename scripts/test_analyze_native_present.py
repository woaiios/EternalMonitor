import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from scripts.analyze_native_present import analyze


class NativePresentAnalysisTest(unittest.TestCase):
    def test_uses_gpu_and_presented_timestamps_not_callback_arrival(self):
        events = [{"event": "metadata", "start": 10, "duration": 30}]
        for i, begin in enumerate([16, 16.008333, 17], 1):
            events.extend([
                {"event": "submit", "id": i, "begin": begin, "acquired": begin + .0001,
                 "submit_end": begin + .0002, "callback": begin - .007,
                 "deadline": begin + .001, "target": begin + .009},
                {"event": "gpu", "id": i, "start": begin + .0003, "end": begin + .0005,
                 "status": 4, "callback": begin + .003},
                {"event": "presented", "id": i, "time": begin + .009 if i < 3 else 0,
                 "callback": begin + .015}])
        with TemporaryDirectory() as directory:
            trace = Path(directory) / "test.jsonl"
            trace.write_text("\n".join(map(json.dumps, events)), encoding="utf-8")
            report = analyze(trace)
        self.assertEqual(report["selected_submissions"], 3)
        self.assertEqual(report["matched_presented_frames"], 2)
        self.assertEqual(report["zero_presented"], 1)
        self.assertEqual(report["stages"]["gpu_end_to_presented"]["p50_ms"], 8.5)
        self.assertEqual(report["stages"]["gpu_render"]["p50_ms"], .2)
        self.assertEqual(report["actual_present_interval"]["p50_ms"], 8.333)


if __name__ == "__main__":
    unittest.main()
