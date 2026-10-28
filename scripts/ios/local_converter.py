#!/usr/bin/env python3
"""Bounded, local-file-only CPU video -> the unchanged iOS Tendies exporter.

Call ``convert`` from a single-worker server; only the HTTP layer owns upload
paths/authentication. CLI paths are trusted PC operator input, read-only. Output
is always job_dir/output.tendies. Pixel size is independent of the fixed logical
iPad Pro 11 M4 screen class (834x1210 points @2x). JPEG q=2 is the best supported
setting (FFmpeg MJPEG quantizer range 2..31); there is no GPU or audio processing.
Failures keep bounded staging/logs for the job owner to remove, never a completed
output. Tool stderr is private diagnostic data and must not be rendered by HTTP.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import plistlib
import re
import shutil
import subprocess
import sys
import threading
import time
import zipfile
import xml.etree.ElementTree as ET
from fractions import Fraction
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lib.paths import ROOT  # noqa: E402

MAX_INPUT_BYTES = 2 * 1024**3
MAX_FRAMES = 18_000
MAX_FRAME_BYTES = 1_800_000_000
MAX_ARCHIVE_BYTES = 1_900_000_000
MAX_JOB_BYTES = 3_800_000_000
MAX_SECONDS = 600
MAX_RUNTIME_SECONDS = 1800
MIN_FREE_BYTES = 128 * 1024**2
PACKAGE_LAYOUT_METADATA_COUNTS = {"legacy": 12, "posterBoard27": 18}
PACKAGE_LAYOUTS = frozenset(PACKAGE_LAYOUT_METADATA_COUNTS)
CORE_FILES = tuple(ROOT / "iOS/Sources/Export" / (name + ".swift") for name in (
    "ExportGeometry", "WallpaperExportSettings", "TendiesScreenClass",
    "TendiesManifest", "TendiesPosterBoard27", "KeyedArchiveBuilder", "ZipArchiveWriter"))
PACKAGER_SOURCE = Path(__file__).with_name("package_tendies_frames.swift")
_BUILD_LOCK = threading.Lock()


class ConverterError(Exception):
    """Safe fixed diagnostic, suitable for a server response (never raw tool output)."""
    def __init__(self, code: str, message: str):
        self.code = code
        self.message = message
        super().__init__(message)


def _fail(code: str, message: str) -> None:
    raise ConverterError(code, message)


def _local_file(path: Path) -> Path:
    text = str(path)
    if (text.startswith(("//", "\\\\")) or
            re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", text) and not re.match(r"^[a-zA-Z]:[\\/]", text)):
        _fail("input", "Select a local video file, not a URL or network path.")
    result = path.resolve(strict=True)
    if str(result).startswith(("//", "\\\\")) or not result.is_file():
        _fail("input", "Select a regular local video file.")
    if os.name == "nt":
        import ctypes
        if ctypes.windll.kernel32.GetDriveTypeW(str(result.anchor)) == 4:
            _fail("input", "Network drives are not supported.")
    if not 0 < result.stat().st_size <= MAX_INPUT_BYTES:
        _fail("input_size", "Input must be non-empty and no larger than 2 GiB.")
    if result.suffix.lower() not in {".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi"}:
        _fail("input", "Use an MP4, MOV, MKV, WebM, or AVI video file.")
    return result


def validate_input(path: Path) -> Path:
    """Read-only local-path, format and size guard; does not probe or decode.

    Server PC-path enqueue should call this before copying to its owned job input.
    It is never an HTTP arbitrary-path entry point.
    """
    try:
        return _local_file(Path(path))
    except ConverterError:
        raise
    except OSError:
        raise ConverterError("input", "Select a readable regular local video file.") from None


def _options(fps: int, width: int, height: int, quality: int, duration: float | None,
             package_layout: str = "legacy") -> None:
    if type(fps) is not int or not 1 <= fps <= 120:
        _fail("options", "Frame rate must be an integer from 1 to 120.")
    if (type(width) is not int or type(height) is not int or
            not 64 <= width <= 4096 or not 64 <= height <= 4096 or
            width % 2 or height % 2 or width * height > 12_000_000):
        _fail("options", "Dimensions must be even, 64 to 4096, and at most 12 million pixels.")
    if type(quality) is not int or not 2 <= quality <= 31:
        _fail("options", "JPEG quality must be an integer from 2 (best) to 31.")
    if duration is not None and (isinstance(duration, bool) or not isinstance(duration, (float, int)) or
                                 not math.isfinite(duration) or not 0 < duration <= MAX_SECONDS):
        _fail("options", "Duration must be positive and no longer than 600 seconds.")
    if type(package_layout) is not str or package_layout not in PACKAGE_LAYOUTS:
        _fail("options", "Package layout is unsupported.")


def _tool(name: str) -> Path:
    found = shutil.which(name)
    fallback = Path("C:/FFmpeg/bin") / (name + ".exe")
    if not found and name in {"ffmpeg", "ffprobe"} and fallback.is_file():
        found = str(fallback)
    if not found:
        _fail("tool_missing", "Required local tool is unavailable: " + name + ".")
    return Path(found).resolve()


def _size(path: Path) -> int:
    return path.stat().st_size if path.is_file() else 0


def _usage(job: Path) -> tuple[int, int]:
    total = 0
    frames = 0
    for entry in job.iterdir():
        if entry.is_file():
            total += entry.stat().st_size
    folder = job / "frames"
    if folder.is_dir():
        with os.scandir(folder) as entries:
            for entry in entries:
                if entry.is_file(follow_symlinks=False):
                    size = entry.stat(follow_symlinks=False).st_size
                    frames += size
                    total += size
    return total, frames


def _run(command: list[str], job: Path, label: str, cancel: threading.Event,
         deadline: float, tick: Callable[[], None] | None = None) -> Path:
    stdout = job / (label + ".stdout")
    stderr = job / (label + ".stderr.log")
    with stdout.open("xb") as out, stderr.open("xb") as err:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                 creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        try:
            while True:
                if cancel.is_set():
                    _fail("cancelled", "Conversion cancelled.")
                if time.monotonic() >= deadline:
                    _fail("timeout", "Conversion exceeded its time limit.")
                total, frames = _usage(job)
                if (total >= MAX_JOB_BYTES or frames >= MAX_FRAME_BYTES or
                        _size(stderr) > 8 * 1024**2 or _size(stdout) > 1024**2 or
                        _size(job / "decode.progress") > 2 * 1024**2):
                    _fail("size_limit", "Conversion reached its disk or archive size limit.")
                if shutil.disk_usage(job).free < MIN_FREE_BYTES:
                    _fail("disk_space", "Insufficient free disk space for conversion.")
                if tick:
                    tick()
                result = child.poll()
                if result is not None:
                    if result:
                        _fail(label + "_failed", "Local " + label + " step failed.")
                    break
                cancel.wait(0.25)
        finally:
            if child.poll() is None:
                child.kill()  # Only this exact child; never process-name/global termination.
                child.wait(timeout=10)
    return stdout


def _rational(value: object) -> Fraction:
    try:
        result = Fraction(str(value).replace(":", "/"))
        if result <= 0:
            raise ValueError
        return result
    except (ValueError, ZeroDivisionError):
        _fail("probe", "Video timing or sample aspect ratio is unknown or invalid.")


def _sample_aspect(value: object) -> tuple[Fraction, bool]:
    """Use stored pixel geometry only when FFmpeg explicitly leaves SAR unspecified.

    Missing/N/A and 0/1 mean unknown, not anamorphic. They are interpreted as
    square pixels and reported as an assumption; malformed and known non-square
    ratios remain unsupported. Timing rationals must never use this fallback.
    """
    if value is None or isinstance(value, str) and value in ("N/A", "0:1", "0/1"):
        return Fraction(1, 1), True
    if not isinstance(value, str):
        _fail("probe", "Source sample aspect ratio is invalid.")
    ratio = _rational(value)
    if ratio != 1:
        _fail("probe", "Only square-pixel source video is supported.")
    return ratio, False


def _probe_info(data: dict, fps: int, duration: float | None) -> dict:
    streams = data.get("streams", [])
    if len(streams) != 1:
        _fail("probe", "No supported video stream was found.")
    stream = streams[0]
    width, height = stream.get("width", 0), stream.get("height", 0)
    if (type(width) is not int or type(height) is not int or not 1 <= width <= 8192 or
            not 1 <= height <= 8192 or width * height > 33_554_432):
        _fail("probe", "Source video dimensions are unsupported.")
    source_fps = _rational(stream.get("avg_frame_rate", "0/0"))
    nominal_fps = _rational(stream.get("r_frame_rate", "0/0"))
    if source_fps > 120 or nominal_fps > 120:
        _fail("probe", "Source frame rate exceeds 120 fps.")
    # Unknown SAR preserves stored width/height; explicit non-square still fails.
    sample_aspect, sample_aspect_assumed = _sample_aspect(stream.get("sample_aspect_ratio"))
    rotation = stream.get("tags", {}).get("rotate", 0)
    for side in stream.get("side_data_list", []):
        if "rotation" in side:
            rotation = side["rotation"]
    try:
        rotation = float(rotation)
        if not math.isfinite(rotation) or rotation % 90:
            raise ValueError
        source_duration = float(stream.get("duration") or data.get("format", {}).get("duration"))
        if not math.isfinite(source_duration) or not 0 < source_duration <= MAX_SECONDS:
            raise ValueError
    except (TypeError, ValueError):
        _fail("probe", "Video duration or rotation is unknown or unsupported.")
    if duration is not None and duration > source_duration + 0.000001:
        _fail("duration", "Requested duration exceeds the source video.")
    used_duration = source_duration if duration is None else duration
    count = max(1, int(math.floor(used_duration * fps + 0.5)))
    # CFR full-source exports at the same rate use the container's exact frame count.
    raw_count = stream.get("nb_frames", "")
    if duration is None and source_fps == nominal_fps == fps and str(raw_count).isdigit():
        count = int(raw_count)
        if abs(count / fps - source_duration) > max(0.1, 2 / fps):
            _fail("probe", "Video frame count and duration disagree.")
    if not 1 <= count <= MAX_FRAMES:
        _fail("frame_limit", "Requested output exceeds the 18000-frame limit.")
    return {"count": count, "duration": used_duration, "source_fps": str(source_fps),
            "width": width, "height": height, "rotation": rotation,
            "sample_aspect_ratio": f"{sample_aspect.numerator}:{sample_aspect.denominator}",
            "sample_aspect_ratio_assumed": sample_aspect_assumed}


def _build_packager(job: Path, cancel: threading.Event, deadline: float) -> Path:
    swiftc = _tool("swiftc")
    digest = hashlib.sha256(str(swiftc).encode())
    digest.update(str(swiftc.stat().st_mtime_ns).encode())
    for source in (*CORE_FILES, PACKAGER_SOURCE):
        digest.update(source.read_bytes())
    cache = job.parent / "toolchain" / digest.hexdigest()[:24]
    binary = cache / ("package-tendies.exe" if os.name == "nt" else "package-tendies")
    # The server is a single worker; this additionally serializes same-process callers.
    while not _BUILD_LOCK.acquire(timeout=0.25):
        if cancel.is_set():
            _fail("cancelled", "Conversion cancelled.")
        if time.monotonic() >= deadline:
            _fail("timeout", "Conversion exceeded its time limit.")
    try:
        if not binary.is_file():
            cache.mkdir(parents=True, exist_ok=True)
            building = job / ("packager-build.exe" if os.name == "nt" else "packager-build")
            _run([str(swiftc), "-O", "-parse-as-library", *map(str, CORE_FILES),
                  str(PACKAGER_SOURCE), "-o", str(building)], job, "compile", cancel,
                 min(deadline, time.monotonic() + 180))
            # A cancelled/failed compiler can never populate the executable cache.
            building.replace(binary)
        return binary
    finally:
        _BUILD_LOCK.release()


def _decode_command(ffmpeg: Path, source: Path, job: Path, fps: int, width: int,
                    height: int, quality: int, count: int) -> list[str]:
    filters = (f"fps={fps},scale={width}:{height}:force_original_aspect_ratio=decrease:"
               f"flags=lanczos,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1")
    return [str(ffmpeg), "-nostdin", "-v", "error", "-nostats", "-n", "-threads", "4",
            "-filter_threads", "1", "-protocol_whitelist", "file", "-format_whitelist",
            "mov,matroska,webm,avi", "-i", str(source), "-map", "0:v:0", "-an", "-sn", "-dn",
            "-vf", filters, "-frames:v", str(count), "-q:v", str(quality), "-pix_fmt", "yuvj444p",
            "-c:v", "mjpeg", "-threads", "4", "-start_number", "0", "-progress",
            str(job / "decode.progress"), str(job / "frames/frame-%05d.jpg")]


def _jpeg_size(data: bytes) -> tuple[int, int]:
    if not data.startswith(b"\xff\xd8") or not data.endswith(b"\xff\xd9"):
        _fail("validation", "A generated JPEG is incomplete.")
    pos = 2
    while pos + 4 <= len(data):
        if data[pos] != 255:
            break
        while pos < len(data) and data[pos] == 255:
            pos += 1
        marker = data[pos]
        pos += 1
        length = int.from_bytes(data[pos:pos + 2], "big")
        if length < 2 or pos + length > len(data):
            break
        if marker in {0xC0, 0xC1, 0xC2} and length >= 8:
            return (int.from_bytes(data[pos + 5:pos + 7], "big"),
                    int.from_bytes(data[pos + 3:pos + 5], "big"))
        if marker == 0xDA:
            break
        pos += length
    _fail("validation", "A generated JPEG has unsupported dimensions.")


def _validate(output: Path, count: int, width: int, height: int, fps: int,
              cancel: threading.Event, deadline: float,
              package_layout: str = "legacy") -> None:
    if not 0 < output.stat().st_size < MAX_ARCHIVE_BYTES:
        _fail("validation", "Generated archive exceeds the supported size limit.")
    with zipfile.ZipFile(output) as archive:
        entries = archive.infolist()
        names = {entry.filename for entry in entries}
        metadata_count = PACKAGE_LAYOUT_METADATA_COUNTS.get(package_layout)
        if metadata_count is None:
            _fail("validation", "Generated archive uses an unsupported package layout.")
        if len(names) != len(entries) or len(entries) != count + metadata_count:
            _fail("validation", "Generated archive has an invalid entry count.")
        jpgs = sorted(name for name in names if name.endswith(".jpg"))
        if len(jpgs) != count or not jpgs:
            _fail("validation", "Generated archive has an invalid frame sequence.")
        assets = jpgs[0].rsplit("/", 1)[0]
        if jpgs != [f"{assets}/{index:05d}.jpg" for index in range(count)]:
            _fail("validation", "Generated archive frames are not contiguous.")
        metadata: dict[str, bytes] = {}
        for entry in entries:
            if cancel.is_set():
                _fail("cancelled", "Conversion cancelled.")
            if time.monotonic() >= deadline:
                _fail("timeout", "Conversion exceeded its time limit.")
            if (not entry.filename.startswith("descriptors/") or ".." in entry.filename.split("/") or
                    entry.compress_type != zipfile.ZIP_STORED or entry.file_size > 64 * 1024**2):
                _fail("validation", "Generated archive contains an invalid member.")
            if not entry.filename.endswith(".jpg") and entry.file_size > 2 * 1024**2:
                _fail("validation", "Generated archive metadata exceeds the supported limit.")
            data = archive.read(entry)  # ZipFile verifies every CRC; one frame in memory.
            if entry.filename.endswith(".jpg"):
                if _jpeg_size(data) != (width, height):
                    _fail("validation", "Generated JPEG dimensions do not match the request.")
            else:
                metadata[entry.filename] = data
                if entry.filename.endswith((".plist", "index.xml", ".userInfo")):
                    plistlib.loads(data)
                elif entry.filename.endswith(".caml"):
                    ET.fromstring(data)
        background = assets.rsplit("/", 1)[0]
        xml = ET.fromstring(metadata[background + "/main.caml"])
        refs = [node.attrib["src"] for node in xml.iter() if "src" in node.attrib]
        expected = [f"assets/{index:05d}.jpg" for index in range(count)]
        if refs != [expected[0], *expected]:
            _fail("validation", "Generated animation references do not match the frame sequence.")
        animation = next(node for node in xml.iter() if node.tag.endswith("animation"))
        if not math.isclose(float(animation.attrib["duration"]), count / fps, abs_tol=0.000001):
            _fail("validation", "Generated animation timing does not match the request.")
        wallpaper_folder = background.rsplit("/", 1)[0]
        wallpaper = plistlib.loads(metadata[wallpaper_folder + "/Wallpaper.plist"])
        if not isinstance(wallpaper, dict):
            _fail("validation", "Generated wallpaper metadata must be a dictionary.")
        if wallpaper.get("logicalScreenClass") != "834w-1210h@2x~ipad":
            _fail("validation", "Generated wallpaper has an unexpected logical screen class.")
        index = plistlib.loads(metadata[background + "/index.xml"])
        if not isinstance(index, dict) or index.get("rootDocument") != "main.caml":
            _fail("validation", "Generated animation index does not declare its root document.")
        if package_layout == "posterBoard27":
            asset = wallpaper
            for key in ("assets", "lockAndHome", "default"):
                asset = asset.get(key)
                if not isinstance(asset, dict):
                    _fail("validation", "Modern package asset metadata must contain dictionaries.")
            plane_names = [asset.get(key) for key in (
                "backgroundAnimationFileName", "floatingAnimationFileNameKey",
                "foregroundAnimationFileName")]
            if any(not isinstance(name, str) or not name.endswith(".ca") or
                   "/" in name or "\\" in name for name in plane_names):
                _fail("validation", "Modern package metadata contains an invalid plane reference.")
            if (len(set(plane_names)) != 3 or
                    f"{wallpaper_folder}/{plane_names[0]}" != background or
                    any(f"{wallpaper_folder}/{name}/main.caml" not in metadata
                        for name in plane_names)):
                _fail("validation", "Modern package metadata does not contain all published planes.")
            for name in plane_names:
                index_data = metadata.get(f"{wallpaper_folder}/{name}/index.xml")
                if index_data is None:
                    _fail("validation", "Modern package plane index is missing.")
                plane_index = plistlib.loads(index_data)
                if not isinstance(plane_index, dict) or plane_index.get("rootDocument") != "main.caml":
                    _fail("validation", "Modern package plane index does not declare its root document.")
            if wallpaper.get("family") != "Clownfish":
                _fail("validation", "Modern package metadata has an unexpected family.")


def convert(input_path: Path, job_dir: Path, *, title: str, fps: int = 60,
            width: int = 1668, height: int = 2420, quality: int = 2,
            duration: float | None = None, package_layout: str = "legacy",
            progress: Callable[[dict], None] | None = None,
            cancel_event: threading.Event | None = None) -> Path:
    """Convert a trusted local path into a new output.tendies without editing input.

    Progress keys: stage, current, total, output_bytes, title. After probing,
    sample_aspect_ratio and sample_aspect_ratio_assumed report normalized geometry.
    Stages: preparing, decoding, packaging, validating, done, failure. Never expose
    diagnostic logs.
    Reusing a job directory with staging/output is rejected; it may contain input.
    """
    cancel = cancel_event if cancel_event is not None else threading.Event()
    deadline = time.monotonic() + MAX_RUNTIME_SECONDS
    raw_job = Path(job_dir)
    if raw_job.is_symlink():
        _fail("job", "Job directory must not be a symbolic link.")
    job = raw_job.resolve()
    output = job / "output.tendies"
    started = False
    count = 0
    sample_aspect_metadata: dict = {}
    safe_title = "".join(c for c in str(title) if c.isalnum() or c in " -_").strip()[:64] or "Wallpaper"

    def emit(stage: str, current: int = 0) -> None:
        if progress:
            progress({"stage": stage, "current": current, "total": count,
                      "output_bytes": _size(output) or _size(job / "output.tendies.partial"),
                      "title": safe_title, **sample_aspect_metadata})

    try:
        _options(fps, width, height, quality, duration, package_layout)
        source = validate_input(Path(input_path))
        if job.exists() and (job.is_symlink() or not job.is_dir()):
            _fail("job", "Job directory must be a regular local directory.")
        job.mkdir(parents=True, exist_ok=True)
        if any((job / name).exists() for name in ("frames", "output.tendies", "output.tendies.partial",
                                                 "probe.stdout", "package-request.json")):
            _fail("job", "Use a fresh job directory for each conversion.")
        if shutil.disk_usage(job).free < 512 * 1024**2:
            _fail("disk_space", "At least 512 MiB of free disk space is required.")
        if cancel.is_set():
            _fail("cancelled", "Conversion cancelled.")
        started = True
        emit("preparing")
        probe = _run([str(_tool("ffprobe")), "-v", "error", "-threads", "4", "-protocol_whitelist", "file",
                      "-format_whitelist", "mov,matroska,webm,avi", "-select_streams", "v:0",
                      "-show_entries", "stream=width,height,avg_frame_rate,r_frame_rate,duration,nb_frames,"
                      "sample_aspect_ratio:stream_tags=rotate:stream_side_data=rotation:format=duration",
                      "-of", "json", str(source)], job, "probe", cancel,
                     min(deadline, time.monotonic() + 30))
        if probe.stat().st_size > 65_536:
            _fail("probe", "Video metadata exceeds the supported limit.")
        info = _probe_info(json.loads(probe.read_text(encoding="utf-8")), fps, duration)
        count = info["count"]
        sample_aspect_metadata = {key: info[key] for key in
                                  ("sample_aspect_ratio", "sample_aspect_ratio_assumed")}
        emit("preparing")
        binary = _build_packager(job, cancel, deadline)
        (job / "frames").mkdir()
        emit("decoding")

        def decoding_tick() -> None:
            path = job / "decode.progress"
            current = 0
            if path.is_file():
                with path.open("rb") as handle:
                    handle.seek(max(0, path.stat().st_size - 8192))
                    matches = re.findall(rb"(?:^|\n)frame=(\d+)", handle.read(8192))
                    if matches:
                        current = min(count, int(matches[-1]))
            emit("decoding", current)

        _run(_decode_command(_tool("ffmpeg"), source, job, fps, width, height, quality, count),
             job, "decode", cancel, deadline, decoding_tick)
        frames = job / "frames"
        if sorted(path.name for path in frames.iterdir()) != [f"frame-{i:05d}.jpg" for i in range(count)]:
            _fail("frame_count", "Decoded frame count differs from the requested timeline.")
        if _usage(job)[1] >= MAX_FRAME_BYTES:
            _fail("size_limit", "Frames exceed the supported archive size limit.")
        request = job / "package-request.json"
        request.write_text(json.dumps({"framesDir": str(frames), "output": str(output),
                                      "width": width, "height": height, "fps": fps, "count": count,
                                      "name": safe_title,
                                      "packageLayout": package_layout}, ensure_ascii=False), encoding="utf-8")
        emit("packaging", count)
        _run([str(binary), str(request)], job, "package", cancel, deadline,
             lambda: emit("packaging", count))
        emit("validating", count)
        _validate(output, count, width, height, fps, cancel, deadline, package_layout)
        emit("done", count)
        return output
    except Exception as error:
        if started and output.is_file():
            # The only completed path created by this attempt; originals are never removed.
            output.unlink()
        emit("failure")
        if isinstance(error, ConverterError):
            raise
        raise ConverterError("conversion_failed", "Local video conversion failed.") from None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("job_dir", type=Path)
    parser.add_argument("--title", default="Wallpaper")
    parser.add_argument("--fps", type=int, default=60)
    parser.add_argument("--width", type=int, default=1668)
    parser.add_argument("--height", type=int, default=2420)
    parser.add_argument("--quality", type=int, default=2)
    parser.add_argument("--duration", type=float)
    parser.add_argument("--package-layout", choices=sorted(PACKAGE_LAYOUTS), default="legacy")
    args = parser.parse_args()
    try:
        output = convert(args.input, args.job_dir, title=args.title, fps=args.fps,
                         width=args.width, height=args.height, quality=args.quality,
                         duration=args.duration, package_layout=args.package_layout,
                         progress=lambda event: print(json.dumps(event, ensure_ascii=False), flush=True))
        print(json.dumps({"output": str(output)}, ensure_ascii=False))
        return 0
    except ConverterError as error:
        print(json.dumps({"error": error.code, "message": error.message}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
