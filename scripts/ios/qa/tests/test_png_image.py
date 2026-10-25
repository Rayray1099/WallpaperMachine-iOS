#!/usr/bin/env python3
"""PNG decoding for screenshot diffing: every row filter, corruption, and diffs."""
from __future__ import annotations

import struct
import sys
import unittest
import zlib
from pathlib import Path

QA_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(QA_DIR))

from png_image import PNGError, PNGImage, decode_png, encode_png  # noqa: E402
import frame_evidence  # noqa: E402
from qa_test_support import image_with_rect  # noqa: E402


class DecodeRoundtrip(unittest.TestCase):
    def test_every_row_filter_roundtrips_rgb(self):
        image = PNGImage(width=7, height=5, channels=3,
                         data=bytes((index * 37 + 11) % 256 for index in range(7 * 5 * 3)))
        for filter_type in range(5):
            with self.subTest(filter_type=filter_type):
                decoded = decode_png(encode_png(image, filter_type=filter_type))
                self.assertEqual((decoded.width, decoded.height, decoded.channels), (7, 5, 3))
                self.assertEqual(decoded.data, image.data)

    def test_rgba_drops_alpha_from_rgb_view(self):
        data = bytearray()
        for index in range(4):
            data.extend((index * 10, index * 20, index * 30, 255 - index))
        image = PNGImage(width=2, height=2, channels=4, data=bytes(data))
        decoded = decode_png(encode_png(image))
        self.assertEqual(decoded.rgb(), bytes((0, 0, 0, 10, 20, 30, 20, 40, 60, 30, 60, 90)))

    def test_grayscale_expands_to_rgb(self):
        image = PNGImage(width=2, height=1, channels=1, data=bytes((7, 200)))
        decoded = decode_png(encode_png(image))
        self.assertEqual(decoded.rgb(), bytes((7, 7, 7, 200, 200, 200)))

    def test_rejects_non_png(self):
        with self.assertRaises(PNGError):
            decode_png(b"not a png")

    def test_rejects_bad_crc(self):
        blob = bytearray(encode_png(PNGImage(width=1, height=1, channels=3, data=b"\x01\x02\x03")))
        blob[-20] ^= 0xFF
        with self.assertRaises(PNGError):
            decode_png(bytes(blob))

    def test_rejects_truncated_data(self):
        blob = encode_png(PNGImage(width=3, height=3, channels=3, data=bytes(27)))
        with self.assertRaises(PNGError):
            decode_png(blob[:-20])

    def test_rejects_extra_scanline(self):
        image = PNGImage(width=2, height=1, channels=3, data=bytes(6))
        blob = bytearray(encode_png(image))
        offset = 8
        while offset < len(blob):
            length, kind = struct.unpack(">I4s", blob[offset:offset + 8])
            if kind == b"IDAT":
                payload = blob[offset + 8:offset + 8 + length]
                raw = zlib.decompress(bytes(payload)) + b"\x00" + bytes(6)
                replacement = zlib.compress(raw)
                tail = struct.pack(">I", len(replacement)) + b"IDAT" + replacement
                blob[offset:offset + 8 + length + 4] = (
                    tail + struct.pack(">I", zlib.crc32(b"IDAT" + replacement) & 0xFFFFFFFF))
                break
            offset += 12 + length
        with self.assertRaises(PNGError):
            decode_png(bytes(blob))


class DiffImages(unittest.TestCase):
    def test_identical_frames_have_no_change(self):
        image = frame_evidence.load_frame(encode_png(
            PNGImage(width=10, height=10, channels=3, data=bytes(300))))
        metrics, mask = frame_evidence.diff_images(image, image)
        self.assertEqual(metrics.changed_pixels, 0)
        self.assertEqual(metrics.changed_ratio, 0.0)
        self.assertEqual(len(mask), 100)

    def test_moved_rectangle_changes_content_and_bounds(self):
        first = frame_evidence.load_frame(encode_png(image_with_rect(10, 10, (1, 1, 2, 2))))
        second = frame_evidence.load_frame(encode_png(image_with_rect(10, 10, (5, 5, 2, 2))))
        metrics, mask = frame_evidence.diff_images(first, second)
        self.assertEqual(metrics.changed_pixels, 8)
        self.assertEqual(metrics.bbox, (1, 1, 6, 6))
        self.assertEqual(sum(mask), 8)

    def test_dimension_mismatch_is_rejected(self):
        small = PNGImage(width=1, height=1, channels=3, data=bytes(3))
        large = PNGImage(width=2, height=1, channels=3, data=bytes(6))
        with self.assertRaises(frame_evidence.FrameMismatch):
            frame_evidence.diff_images(small, large)


class AnimationVerdict(unittest.TestCase):
    def frames(self, rects):
        return [frame_evidence.load_frame(encode_png(image_with_rect(60, 40, rect)))
                for rect in rects]

    def test_static_frames_fail(self):
        frames = self.frames([(4, 4, 20, 12)] * 6)
        verdict = frame_evidence.evaluate_animation(frames)
        self.assertFalse(verdict.passed)
        self.assertIn("changed at least", verdict.reason)
        self.assertEqual(verdict.transition_count, 0)

    def test_advancing_rectangle_passes(self):
        frames = self.frames([(index * 4, 4, 20, 12) for index in range(6)])
        verdict = frame_evidence.evaluate_animation(frames)
        self.assertTrue(verdict.passed, verdict.reason)
        self.assertGreaterEqual(verdict.transition_count, 3)
        self.assertGreaterEqual(verdict.distinct_frames, 4)
        self.assertNotIn("fps", verdict.as_dict())

    def test_single_tiny_change_is_not_animation(self):
        frames = self.frames([(4, 4, 20, 12)] * 6)
        data = bytearray(frames[3].data)
        data[0] ^= 0xFF
        frames[3] = PNGImage(width=frames[3].width, height=frames[3].height,
                             channels=frames[3].channels, data=bytes(data))
        verdict = frame_evidence.evaluate_animation(frames)
        self.assertFalse(verdict.passed)

    def test_too_few_frames_fail(self):
        verdict = frame_evidence.evaluate_animation(self.frames([(0, 0, 5, 5)]))
        self.assertFalse(verdict.passed)
        self.assertIn("at least 2", verdict.reason)

    def test_report_names_content_not_frame_rate(self):
        frames = self.frames([(index * 4, 4, 20, 12) for index in range(6)])
        payload = frame_evidence.evaluate_animation(frames).as_dict()
        self.assertEqual(payload["method"], "lossless PNG pixel diff of the app window")
        self.assertIn("not the application's frame rate", payload["not_fps"])


if __name__ == "__main__":
    unittest.main()
