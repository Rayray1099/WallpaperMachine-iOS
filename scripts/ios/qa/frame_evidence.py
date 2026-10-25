#!/usr/bin/env python3
"""Prove that a wallpaper is animating from screenshot *content*, not timestamps.

The device is asked for lossless PNG screenshots of the app window at intervals.
Each pair is decoded and compared pixel by pixel; the evidence is the measured
fraction of changed pixels, the changed area's bounding box and the number of
distinct sampled frames. Timestamps are scheduling metadata only: a run with
identical pixels never passes, however far apart the captures were.

This deliberately does not report application FPS. Capture and envelope
decryption cost dominates each sample, so the sampling interval says nothing
about the app's frame rate; iCTRL runner metrics are not app metrics.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Sequence

try:
    from .png_image import PNGImage, PNGError
except ImportError:  # pragma: no cover
    from png_image import PNGImage, PNGError  # type: ignore[no-redef]

DEFAULT_MIN_CHANGED_RATIO = 0.01
DEFAULT_MIN_COVERAGE = 0.03
DEFAULT_MIN_TRANSITIONS = 3
DEFAULT_PIXEL_THRESHOLD = 8
GRID = 16


class FrameMismatch(RuntimeError):
    """Frames cannot be compared because their dimensions differ."""


@dataclass(frozen=True)
class PairDiff:
    first: int
    second: int
    changed_pixels: int
    total_pixels: int
    changed_ratio: float
    mean_abs_delta: float
    bbox: tuple[int, int, int, int] | None

    def as_dict(self) -> dict:
        return {
            "pair": [self.first, self.second],
            "changed_pixels": self.changed_pixels,
            "total_pixels": self.total_pixels,
            "changed_ratio": round(self.changed_ratio, 6),
            "mean_abs_delta": round(self.mean_abs_delta, 3),
            "bbox": list(self.bbox) if self.bbox else None,
        }


@dataclass
class AnimationVerdict:
    passed: bool
    reason: str
    transition_count: int
    distinct_frames: int
    coverage_ratio: float
    pairs: list[PairDiff] = field(default_factory=list)
    thresholds: dict = field(default_factory=dict)

    def as_dict(self) -> dict:
        return {
            "method": "lossless PNG pixel diff of the app window",
            "passed": self.passed,
            "reason": self.reason,
            "transition_count": self.transition_count,
            "distinct_sampled_frames": self.distinct_frames,
            "changed_area_coverage_ratio": round(self.coverage_ratio, 6),
            "thresholds": self.thresholds,
            "pairs": [pair.as_dict() for pair in self.pairs],
            "not_fps": (
                "Sampled content change only; capture latency dominates the interval, "
                "so this is not the application's frame rate."),
        }


def diff_images(first: PNGImage, second: PNGImage, *,
                pixel_threshold: int = DEFAULT_PIXEL_THRESHOLD) -> tuple[PairDiff, bytes]:
    """Compare two images; returns metrics plus a 1-byte-per-pixel changed mask."""
    if (first.width, first.height) != (second.width, second.height):
        raise FrameMismatch(
            f"frame sizes differ: {first.width}x{first.height} vs {second.width}x{second.height}")
    if not 0 <= pixel_threshold <= 255:
        raise ValueError("pixel_threshold must be 0..255")
    left = first.rgb()
    right = second.rgb()
    total = first.width * first.height
    mask = bytearray(total)
    changed = 0
    delta_sum = 0
    min_x, min_y, max_x, max_y = first.width, first.height, -1, -1
    for index in range(total):
        base = index * 3
        delta = (abs(left[base] - right[base]) +
                 abs(left[base + 1] - right[base + 1]) +
                 abs(left[base + 2] - right[base + 2]))
        delta_sum += delta
        if max(abs(left[base] - right[base]),
               abs(left[base + 1] - right[base + 1]),
               abs(left[base + 2] - right[base + 2])) > pixel_threshold:
            mask[index] = 1
            changed += 1
            x = index % first.width
            y = index // first.width
            min_x = min(min_x, x)
            max_x = max(max_x, x)
            min_y = min(min_y, y)
            max_y = max(max_y, y)
    bbox = (min_x, min_y, max_x - min_x + 1, max_y - min_y + 1) if changed else None
    metrics = PairDiff(
        first=0,
        second=0,
        changed_pixels=changed,
        total_pixels=total,
        changed_ratio=changed / total if total else 0.0,
        mean_abs_delta=delta_sum / (total * 3) if total else 0.0,
        bbox=bbox,
    )
    return metrics, bytes(mask)


def _signature(image: PNGImage) -> bytes:
    """Coarse, quantized 16x16 RGB thumbnail used to count distinct frames."""
    rgb = image.rgb()
    signature = bytearray()
    for grid_y in range(GRID):
        y0 = grid_y * image.height // GRID
        y1 = max(y0 + 1, (grid_y + 1) * image.height // GRID)
        for grid_x in range(GRID):
            x0 = grid_x * image.width // GRID
            x1 = max(x0 + 1, (grid_x + 1) * image.width // GRID)
            sums = [0, 0, 0]
            count = 0
            for y in range(y0, y1):
                row = y * image.width
                for x in range(x0, x1):
                    base = (row + x) * 3
                    sums[0] += rgb[base]
                    sums[1] += rgb[base + 1]
                    sums[2] += rgb[base + 2]
                    count += 1
            for channel in sums:
                signature.append((channel // count) >> 3)
    return bytes(signature)


def distinct_frame_count(frames: Sequence[PNGImage]) -> int:
    return len({_signature(frame) for frame in frames})


def evaluate_animation(
    frames: Sequence[PNGImage],
    *,
    min_changed_ratio: float = DEFAULT_MIN_CHANGED_RATIO,
    min_coverage: float = DEFAULT_MIN_COVERAGE,
    min_transitions: int = DEFAULT_MIN_TRANSITIONS,
    pixel_threshold: int = DEFAULT_PIXEL_THRESHOLD,
) -> AnimationVerdict:
    """Decide whether sampled screenshots show advancing content.

    Passing requires at least ``min_transitions`` adjacent pairs whose changed
    pixel fraction clears ``min_changed_ratio``, at least ``min_transitions + 1``
    distinct sampled frames, and a union of changed pixels covering
    ``min_coverage`` of the frame. A clock, cursor or single blinking element
    therefore cannot pass as an animated wallpaper.
    """
    thresholds = {
        "min_changed_ratio": min_changed_ratio,
        "min_coverage": min_coverage,
        "min_transitions": min_transitions,
        "pixel_threshold": pixel_threshold,
    }
    if len(frames) < 2:
        return AnimationVerdict(
            passed=False,
            reason=f"only {len(frames)} frame(s) captured; at least 2 are required",
            transition_count=0,
            distinct_frames=len(frames),
            coverage_ratio=0.0,
            thresholds=thresholds,
        )
    pairs: list[PairDiff] = []
    union = bytearray(frames[0].width * frames[0].height)
    for index in range(len(frames) - 1):
        metrics, mask = diff_images(frames[index], frames[index + 1],
                                    pixel_threshold=pixel_threshold)
        pairs.append(PairDiff(
            first=index, second=index + 1,
            changed_pixels=metrics.changed_pixels,
            total_pixels=metrics.total_pixels,
            changed_ratio=metrics.changed_ratio,
            mean_abs_delta=metrics.mean_abs_delta,
            bbox=metrics.bbox,
        ))
        for pixel, changed in enumerate(mask):
            if changed:
                union[pixel] = 1
    transitions = sum(1 for pair in pairs if pair.changed_ratio >= min_changed_ratio)
    distinct = distinct_frame_count(frames)
    coverage = sum(union) / len(union) if union else 0.0

    reasons: list[str] = []
    if transitions < min_transitions:
        reasons.append(
            f"{transitions} of {len(pairs)} adjacent pairs changed at least "
            f"{min_changed_ratio:.1%} (need {min_transitions}); largest was "
            f"{max((pair.changed_ratio for pair in pairs), default=0.0):.2%}")
    if distinct <= min_transitions:
        reasons.append(
            f"{distinct} distinct sampled frames (need more than {min_transitions})")
    if coverage < min_coverage:
        reasons.append(
            f"changed area covered {coverage:.2%} of the frame (need {min_coverage:.1%})")

    if reasons:
        return AnimationVerdict(
            passed=False,
            reason="; ".join(reasons),
            transition_count=transitions,
            distinct_frames=distinct,
            coverage_ratio=coverage,
            pairs=pairs,
            thresholds=thresholds,
        )
    return AnimationVerdict(
        passed=True,
        reason=(
            f"{transitions} transitions >= {min_changed_ratio:.1%}, "
            f"{distinct} distinct sampled frames, changed area {coverage:.2%}"),
        transition_count=transitions,
        distinct_frames=distinct,
        coverage_ratio=coverage,
        pairs=pairs,
        thresholds=thresholds,
    )


def load_frame(blob: bytes) -> PNGImage:
    try:
        from .png_image import decode_png
    except ImportError:  # pragma: no cover
        from png_image import decode_png  # type: ignore[no-redef]
    try:
        return decode_png(blob)
    except PNGError as error:
        raise PNGError(
            f"screenshot cannot be compared ({error}); request format=png, scale<=2") from error
