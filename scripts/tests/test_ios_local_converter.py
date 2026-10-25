"""Pure unit coverage; opt-in CPU integration uses only a self-authored fixture."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "ios/local_converter.py"
spec = importlib.util.spec_from_file_location("ios_local_converter", SOURCE)
assert spec and spec.loader
converter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(converter)


def probe(**changes):
    stream = {"width": 1920, "height": 1080, "avg_frame_rate": "60/1",
              "r_frame_rate": "60/1", "sample_aspect_ratio": "1:1",
              "duration": "30.000000", "nb_frames": "1800"}
    stream.update(changes)
    return {"streams": [stream], "format": {"duration": "30"}}


class LocalConverterTests(unittest.TestCase):
    def test_exact_cfr_frame_count(self):
        self.assertEqual(converter._probe_info(probe(), 60, None)["count"], 1800)
        self.assertEqual(converter._probe_info(probe(duration="29.9999"), 60, None)["count"], 1800)

    def test_explicit_rate_and_duration_are_not_silently_downsampled(self):
        self.assertEqual(converter._probe_info(probe(), 120, 1)["count"], 120)
        self.assertEqual(converter._probe_info(probe(), 60, 0.025)["count"], 2)
        with self.assertRaises(converter.ConverterError):
            converter._probe_info(probe(), 60, 31)
        with self.assertRaises(converter.ConverterError):
            converter._probe_info(probe(duration="600", nb_frames="36000"), 60, None)

    def test_unknown_invalid_geometry_and_timing_rejected(self):
        for changes in ({"avg_frame_rate": "0/0"}, {"duration": "nan"}, {"width": 9000},
                        {"sample_aspect_ratio": "4:3"},
                        {"r_frame_rate": "121/1"}, {"tags": {"rotate": "45"}},
                        {"nb_frames": "20"}):
            with self.subTest(changes=changes), self.assertRaises(converter.ConverterError):
                converter._probe_info(probe(**changes), 60, None)
        info = converter._probe_info(probe(side_data_list=[{"rotation": -90}]), 60, None)
        self.assertEqual(info["rotation"], -90)

    def test_unspecified_sample_aspect_uses_stored_square_pixel_geometry_and_reports_assumption(self):
        for value in (None, "N/A", "0:1", "0/1"):
            with self.subTest(value=value):
                info = converter._probe_info(probe(sample_aspect_ratio=value), 60, None)
                self.assertEqual(info["sample_aspect_ratio"], "1:1")
                self.assertIs(info["sample_aspect_ratio_assumed"], True)
                self.assertEqual((info["width"], info["height"], info["count"]), (1920, 1080, 1800))
        document = probe()
        del document["streams"][0]["sample_aspect_ratio"]
        self.assertIs(converter._probe_info(document, 60, None)["sample_aspect_ratio_assumed"], True)

    def test_explicit_square_samples_are_not_reported_as_assumed(self):
        for value in ("1:1", "1/1", "2:2"):
            with self.subTest(value=value):
                info = converter._probe_info(probe(sample_aspect_ratio=value), 60, None)
                self.assertEqual(info["sample_aspect_ratio"], "1:1")
                self.assertIs(info["sample_aspect_ratio_assumed"], False)

    def test_non_square_and_malformed_sample_aspect_still_fail_without_weakening_timing(self):
        for value in ("4:3", "16:15", "0:0", "1:0", "-1:1", "", "unknown", [], {}, 0, True):
            with self.subTest(value=value), self.assertRaises(converter.ConverterError):
                converter._probe_info(probe(sample_aspect_ratio=value), 60, None)
        for key in ("avg_frame_rate", "r_frame_rate"):
            for value in (None, "N/A", "0:1", "0/1", "0/0"):
                with self.subTest(key=key, value=value), self.assertRaises(converter.ConverterError):
                    converter._probe_info(probe(**{key: value}), 60, None)

    def test_option_limits(self):
        converter._options(60, 1668, 2420, 2, None)
        for options in ((0, 64, 64, 2, None), (True, 64, 64, 2, None),
                        (121, 64, 64, 2, None), (60, 65, 64, 2, None),
                        (60, 4096, 4096, 2, None), (60, 64, 64, 1, None),
                        (60, 64, 64, 2, float("inf")), (60, 64, 64, 2, 601)):
            with self.subTest(options=options), self.assertRaises(converter.ConverterError):
                converter._options(*options)

    def test_urls_and_network_paths_rejected_before_access(self):
        for value in ("https://example.invalid/video.mp4", "file:///video.mp4", "pipe:0",
                      "\\\\server\\share\\video.mp4", "//server/share/video.mp4"):
            with self.subTest(value=value), self.assertRaises(converter.ConverterError):
                converter._local_file(Path(value))

    def test_public_input_validation_is_read_only_and_safe(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.mp4"
            source.write_bytes(b"read-only validation fixture")
            with mock.patch.object(converter.subprocess, "Popen") as popen:
                self.assertEqual(converter.validate_input(source), source.resolve())
                popen.assert_not_called()
            self.assertEqual(source.read_bytes(), b"read-only validation fixture")
            with self.assertRaises(converter.ConverterError) as caught:
                converter.validate_input(source.with_name("PRIVATE_MISSING.mp4"))
            self.assertNotIn("PRIVATE_MISSING", str(caught.exception))
            if os.name == "nt":
                import ctypes
                with mock.patch.object(ctypes.windll.kernel32, "GetDriveTypeW", return_value=4):
                    with self.assertRaises(converter.ConverterError):
                        converter.validate_input(source)

    def test_decode_command_is_cpu_only_and_local(self):
        command = converter._decode_command(Path("ffmpeg"), Path("input.mp4"), Path("job"),
                                            60, 1668, 2420, 2, 1800)
        self.assertIn("file", command)
        self.assertIn("-an", command)
        self.assertIn("-nostdin", command)
        self.assertEqual(command[command.index("-frames:v") + 1], "1800")
        self.assertEqual(command[command.index("-start_number") + 1], "0")
        self.assertIn("fps=60,scale=1668:2420", command[command.index("-vf") + 1])
        self.assertNotIn("-hwaccel", command)
        self.assertEqual(command.count("-threads"), 2)
        self.assertEqual(command[command.index("-filter_threads") + 1], "1")

    def test_cancel_before_process_and_refuse_existing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.mp4"
            source.write_bytes(b"self-authored fixture")
            event = threading.Event()
            event.set()
            with mock.patch.object(converter.subprocess, "Popen") as popen:
                with self.assertRaises(converter.ConverterError) as caught:
                    converter.convert(source, root / "job", title="Test", cancel_event=event)
                self.assertEqual(caught.exception.code, "cancelled")
                popen.assert_not_called()
            job = root / "job"
            job.mkdir(exist_ok=True)
            output = job / "output.tendies"
            output.write_bytes(b"existing output")
            with self.assertRaises(converter.ConverterError):
                converter.convert(source, job, title="Test")
            self.assertEqual(output.read_bytes(), b"existing output")
            self.assertEqual(source.read_bytes(), b"self-authored fixture")

    def test_failed_process_diagnostic_is_safe(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            command = [sys.executable, "-c", "import sys; sys.stderr.write('PRIVATE_PATH'); sys.exit(2)"]
            with self.assertRaises(converter.ConverterError) as caught:
                converter._run(command, root, "fixture", threading.Event(),
                               converter.time.monotonic() + 10)
            self.assertNotIn("PRIVATE_PATH", str(caught.exception))
            self.assertIn("PRIVATE_PATH", (root / "fixture.stderr.log").read_text())

    def test_running_child_is_killed_on_cancellation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            event = threading.Event()
            child = mock.Mock()
            child.poll.return_value = None
            with mock.patch.object(converter.subprocess, "Popen", return_value=child):
                def tick():
                    event.set()
                with self.assertRaises(converter.ConverterError) as caught:
                    converter._run(["fixture"], root, "cancel", event,
                                   converter.time.monotonic() + 10, tick)
            self.assertEqual(caught.exception.code, "cancelled")
            child.kill.assert_called_once_with()
            child.wait.assert_called_once_with(timeout=10)

    def test_disk_budget_stops_child_before_completion(self):
        with tempfile.TemporaryDirectory() as temporary:
            child = mock.Mock()
            child.poll.return_value = None
            with mock.patch.object(converter.subprocess, "Popen", return_value=child), \
                    mock.patch.object(converter, "_usage", return_value=(converter.MAX_JOB_BYTES, 0)):
                with self.assertRaises(converter.ConverterError) as caught:
                    converter._run(["fixture"], Path(temporary), "budget", threading.Event(),
                                   converter.time.monotonic() + 10)
            self.assertEqual(caught.exception.code, "size_limit")
            child.kill.assert_called_once_with()

    @unittest.skipUnless(os.environ.get("IOS_LOCAL_CONVERTER_INTEGRATION") == "1",
                         "Set IOS_LOCAL_CONVERTER_INTEGRATION=1 for CPU-only tiny fixture")
    def test_tiny_self_authored_fixture_actual_swift_exporter(self):
        # No private assets, network, GPU, audio, GUI, device or RPC access.
        with tempfile.TemporaryDirectory(prefix="wm-local-converter-") as temporary:
            root = Path(temporary)
            source = root / "tiny.mp4"
            subprocess.run([str(converter._tool("ffmpeg")), "-nostdin", "-v", "error", "-n",
                            "-f", "lavfi", "-i", "color=c=red:s=64x96:r=60:d=0.05",
                            "-an", "-c:v", "mpeg4", "-threads", "1", str(source)],
                           check=True, stdin=subprocess.DEVNULL, timeout=20)
            original = source.read_bytes()
            events = []
            output = converter.convert(source, root / "job", title="Tiny test", width=64,
                                       height=96, progress=events.append)
            self.assertTrue(output.is_file())
            self.assertEqual(original, source.read_bytes())
            self.assertEqual(events[-1]["stage"], "done")
            self.assertEqual(events[-1]["total"], 3)
            self.assertEqual(events[-1]["sample_aspect_ratio"], "1:1")
            self.assertIs(events[-1]["sample_aspect_ratio_assumed"], False)
            self.assertNotIn(str(root), json.dumps(events))
            converter._validate(output, 3, 64, 96, 60, threading.Event(),
                                converter.time.monotonic() + 20)
            with converter.zipfile.ZipFile(output) as archive:
                self.assertEqual(len(archive.infolist()), 15)
                self.assertIsNone(archive.testzip())

    @unittest.skipUnless(os.environ.get("IOS_LOCAL_CONVERTER_INTEGRATION") == "1",
                         "Set IOS_LOCAL_CONVERTER_INTEGRATION=1 for CPU-only tiny fixture")
    def test_unlabelled_h264_square_pixel_fit_actual_swift_exporter(self):
        # setsar=0 creates real H264 with absent ffprobe SAR/DAR, not mocked metadata.
        # Original authored 16:9 red pixels must stay 16:9 inside the portrait canvas.
        with tempfile.TemporaryDirectory(prefix="wm-unknown-sar-converter-") as temporary:
            root = Path(temporary)
            source = root / "unlabelled.mp4"
            subprocess.run([str(converter._tool("ffmpeg")), "-nostdin", "-v", "error", "-n",
                            "-f", "lavfi", "-i", "color=c=red:s=192x108:r=60:d=0.05",
                            "-vf", "setsar=0", "-an", "-c:v", "libx264", "-threads", "1",
                            "-pix_fmt", "yuv420p", str(source)],
                           check=True, stdin=subprocess.DEVNULL, timeout=20)
            original = source.read_bytes()
            metadata = root / "metadata.json"
            with metadata.open("wb") as out:
                subprocess.run([str(converter._tool("ffprobe")), "-v", "error", "-select_streams", "v:0",
                                "-show_entries", "stream=sample_aspect_ratio,display_aspect_ratio", "-of", "json",
                                str(source)], check=True, stdin=subprocess.DEVNULL, stdout=out, timeout=20)
            stream = json.loads(metadata.read_text(encoding="utf-8"))["streams"][0]
            self.assertNotIn("sample_aspect_ratio", stream)
            self.assertNotIn("display_aspect_ratio", stream)
            events = []
            output = converter.convert(source, root / "job", title="Unspecified aspect", width=64,
                                       height=96, progress=events.append)
            self.assertEqual(original, source.read_bytes())
            self.assertEqual((events[-1]["stage"], events[-1]["total"]), ("done", 3))
            self.assertEqual(events[-1]["sample_aspect_ratio"], "1:1")
            self.assertIs(events[-1]["sample_aspect_ratio_assumed"], True)
            self.assertNotIn(str(root), json.dumps(events))
            converter._validate(output, 3, 64, 96, 60, threading.Event(),
                                converter.time.monotonic() + 20)
            with converter.zipfile.ZipFile(output) as archive:
                self.assertIsNone(archive.testzip())
                frames = sorted((entry for entry in archive.infolist() if entry.filename.endswith(".jpg")),
                                key=lambda entry: entry.filename)
                self.assertEqual(len(frames), 3)
                for frame in frames:
                    self.assertEqual(converter._jpeg_size(archive.read(frame)), (64, 96))
                image = root / "first.jpg"
                image.write_bytes(archive.read(frames[0]))
            pixels = root / "pixels.rgb"
            subprocess.run([str(converter._tool("ffmpeg")), "-nostdin", "-v", "error", "-n",
                            "-i", str(image), "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", str(pixels)],
                           check=True, stdin=subprocess.DEVNULL, timeout=20)
            data = pixels.read_bytes()
            self.assertEqual(len(data), 64 * 96 * 3)
            red_rows = []
            for y in range(96):
                offset = (y * 64 + 32) * 3
                red, green, blue = data[offset:offset + 3]
                if red > 200 and green < 40 and blue < 40:
                    red_rows.append(y)
            self.assertEqual(red_rows, list(range(30, 66)))


if __name__ == "__main__":
    unittest.main()
