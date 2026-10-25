#!/usr/bin/env python3
"""Serve a single-worker, capability-protected local video-to-tendies converter."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
import hmac
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
from pathlib import Path
import re
import secrets
import shutil
import sys
import threading
from urllib.parse import parse_qs, quote, urlsplit
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lib.paths import ROOT

MAX_INPUT_BYTES = 2 * 1024**3
DEFAULTS = {"fps": 60, "width": 1668, "height": 2420, "quality": 2}
STATIC = Path(__file__).with_name("converter_web")
UUID_PATTERN = re.compile(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}")


def local_host(value: str) -> str:
    address = ipaddress.ip_address(value)
    networks = ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
    if address.version != 4 or not (address.is_loopback or any(address in ipaddress.ip_network(n) for n in networks)):
        raise ValueError("Bind only a specific loopback or private IPv4 address")
    return str(address)


def clean_title(value: str) -> str:
    value = "".join(c for c in value if ord(c) >= 32 and ord(c) != 127).strip()
    if not value or len(value) > 120:
        raise ValueError("Wallpaper name must contain 1–120 visible characters")
    return value


def options_from(query: str) -> tuple[str, dict]:
    values = parse_qs(query, keep_blank_values=True, strict_parsing=True) if query else {}
    if set(values) - {"title", "fps", "width", "height", "quality", "duration"} or any(len(v) != 1 for v in values.values()):
        raise ValueError("Unknown or repeated conversion option")
    title = clean_title(values.pop("title", ["Wallpaper"])[0])
    options = dict(DEFAULTS)
    for key in DEFAULTS:
        if key in values:
            raw = values[key][0]
            if not re.fullmatch(r"[0-9]{1,5}", raw):
                raise ValueError("Invalid numeric option")
            options[key] = int(raw)
    if not 1 <= options["fps"] <= 120 or not 2 <= options["quality"] <= 10:
        raise ValueError("FPS or JPEG quality is out of range")
    if any(not 64 <= options[k] <= 4096 or options[k] % 2 for k in ("width", "height")) or options["width"] * options["height"] > 12_000_000:
        raise ValueError("Output dimensions must be even and bounded")
    if "duration" in values:
        raw = values["duration"][0]
        if not re.fullmatch(r"[0-9]{1,3}(?:\.[0-9]{1,3})?", raw) or not 0 < float(raw) <= 600:
            raise ValueError("Duration must be positive and at most 600 seconds")
        options["duration"] = float(raw)
    return title, options


@dataclass
class Job:
    id: str
    title: str
    directory: Path
    options: dict
    state: str = "uploading"
    progress: dict = field(default_factory=dict)
    error: str | None = None
    download_key: str = field(default_factory=lambda: secrets.token_urlsafe(24))
    cancel: threading.Event = field(default_factory=threading.Event)
    output: Path | None = None
    sha256: str | None = None
    sample_aspect_ratio_assumed: bool = False

    def public(self) -> dict:
        result = {"id": self.id, "title": self.title, "state": self.state,
                  "progress": dict(self.progress), "error": self.error,
                  "sample_aspect_ratio_assumed": self.sample_aspect_ratio_assumed}
        if self.state == "done" and self.output is not None:
            result["sha256"] = self.sha256
            result["bytes"] = self.output.stat().st_size
            result["download_url"] = f"/api/jobs/{self.id}/download?key={self.download_key}"
        return result


class ConverterState:
    def __init__(self, root: Path, converter, token: str | None):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.jobs_root = self.root / "jobs"
        self.jobs_root.mkdir(exist_ok=True)
        self.token = token or secrets.token_urlsafe(32)
        self.converter = converter
        self.lock = threading.Lock()
        self.active: str | None = None
        self.jobs: dict[str, Job] = {}
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="local-converter")
        self.closed = False
        self._restore_completed()

    @staticmethod
    def _digest(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()

    def _restore_completed(self):
        # Restore only this server's explicit completion receipts, never infer a
        # successful conversion from an interrupted output file's existence.
        directories = sorted(self.jobs_root.iterdir(), key=lambda p: p.name)
        for directory in directories[:1000]:
            receipt = directory / "completed.json"
            output = directory / "output.tendies"
            try:
                if (not UUID_PATTERN.fullmatch(directory.name) or directory.is_symlink()
                        or not directory.is_dir() or receipt.is_symlink() or not receipt.is_file()
                        or receipt.stat().st_size > 8192 or output.is_symlink() or not output.is_file()
                        or directory.resolve().parent != self.jobs_root.resolve()):
                    continue
                value = json.loads(receipt.read_text(encoding="utf-8"))
                if (not isinstance(value, dict) or not isinstance(value.get("options"), dict)
                        or value.get("schema") != 1 or value.get("id") != directory.name
                        or type(value.get("bytes")) is not int or not 0 < value["bytes"] < 1_900_000_000
                        or value.get("bytes") != output.stat().st_size
                        or not re.fullmatch(r"[0-9a-f]{64}", value.get("sha256", ""))
                        or self._digest(output) != value["sha256"]):
                    continue
                title, options = options_from("title=" + quote(clean_title(value["title"])) + "".join(f"&{k}={v}" for k, v in value["options"].items()))
                assumed = value.get("sample_aspect_ratio_assumed", False)
                if type(assumed) is not bool:
                    continue
                job = Job(directory.name, title, directory, options, state="done", output=output, sha256=value["sha256"], sample_aspect_ratio_assumed=assumed)
                job.progress = {"stage": "done", "output_bytes": output.stat().st_size}
                self.jobs[job.id] = job  # New per-boot download capability.
            except (OSError, ValueError, TypeError, KeyError):
                continue
            if len(self.jobs) >= 20:
                break

    def _save_completed(self, job: Job, output: Path):
        receipt = job.directory / "completed.json"
        staging = job.directory / "completed.json.partial"
        value = {"schema": 1, "id": job.id, "title": job.title, "options": job.options,
                 "bytes": output.stat().st_size, "sha256": self._digest(output),
                 "sample_aspect_ratio_assumed": job.sample_aspect_ratio_assumed}
        with staging.open("x", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False)
        with self.lock:
            if job.cancel.is_set():
                # This fixed staging receipt was created above by this method.
                if staging.resolve().parent != job.directory.resolve():
                    raise RuntimeError("Invalid receipt location")
                staging.unlink()
                job.state = "cancelled"
                return
            staging.replace(receipt)
            job.output = output
            job.sha256 = value["sha256"]
            job.state = "done"
            job.progress = {"stage": "done", "output_bytes": output.stat().st_size}

    def reserve(self, title: str, options: dict) -> Job:
        with self.lock:
            if self.closed or self.active is not None:
                raise RuntimeError("busy")
            if len(self.jobs) >= 20:
                raise RuntimeError("full")
            identifier = str(uuid.uuid4())
            directory = self.jobs_root / identifier
            directory.mkdir()
            job = Job(identifier, title, directory, dict(options))
            self.jobs[identifier] = job
            self.active = identifier
            return job

    def discard_upload(self, job: Job) -> None:
        # Only remove the new UUID directory created/reserved by this state.
        target = job.directory.resolve()
        if target.parent != self.jobs_root.resolve() or target.name != job.id or not UUID_PATTERN.fullmatch(target.name) or job.directory.is_symlink():
            raise RuntimeError("Refusing unowned upload cleanup")
        shutil.rmtree(target)
        with self.lock:
            self.jobs.pop(job.id, None)
            if self.active == job.id:
                self.active = None

    def submit(self, job: Job) -> None:
        with self.lock:
            job.state = "queued"
        self.executor.submit(self._run, job)

    def _run(self, job: Job) -> None:
        def progress(value):
            safe = {k: value[k] for k in ("stage", "current", "total", "output_bytes") if k in value}
            with self.lock:
                if type(value.get("sample_aspect_ratio_assumed")) is bool:
                    job.sample_aspect_ratio_assumed = value["sample_aspect_ratio_assumed"]
                job.progress = safe
        try:
            with self.lock:
                job.state = "converting"
            if job.cancel.is_set():
                raise RuntimeError("cancelled")
            raw_output = Path(self.converter(job.directory / "input.mp4", job.directory,
                                         title=job.title, progress=progress, cancel_event=job.cancel, **job.options))
            if raw_output != job.directory / "output.tendies" or raw_output.is_symlink():
                raise RuntimeError("invalid output")
            output = raw_output.resolve()
            if output.parent != job.directory.resolve() or not output.is_file():
                raise RuntimeError("invalid output")
            if not job.cancel.is_set():
                self._save_completed(job, output)
            with self.lock:
                if job.cancel.is_set():
                    job.state = "cancelled"
                    for name in ("completed.json", "completed.json.partial"):
                        receipt = job.directory / name
                        if receipt.exists():
                            if receipt.resolve().parent != job.directory.resolve() or receipt.is_symlink():
                                raise RuntimeError("Invalid receipt location")
                            receipt.unlink()
                else:
                    job.output = output
                    job.state = "done"
                    job.progress = {"stage": "done", "output_bytes": output.stat().st_size}
        except Exception as error:
            # Only the engine's bounded error code is rendered; never str(error),
            # subprocess stderr, filenames or filesystem paths from arbitrary errors.
            code = getattr(error, "code", "conversion_failed")
            if not isinstance(code, str) or not re.fullmatch(r"[a-z_]{1,48}", code):
                code = "conversion_failed"
            with self.lock:
                job.state = "cancelled" if job.cancel.is_set() else "failed"
                job.error = code
        finally:
            with self.lock:
                if self.active == job.id:
                    self.active = None

    def enqueue_local(self, path: Path, title: str, **options) -> Job:
        path = Path(path)
        if str(path).startswith(("\\\\", "//")):
            raise ValueError("Network input paths are not accepted")
        from local_converter import validate_input
        path = validate_input(path)
        if not path.is_file() or not 0 < path.stat().st_size <= MAX_INPUT_BYTES:
            raise ValueError("Invalid local input")
        # This method is called only from the local CLI, never an HTTP parameter.
        title, settings = options_from("title=" + quote(title) + "".join(f"&{k}={v}" for k, v in options.items()))
        job = self.reserve(title, settings)
        try:
            shutil.copyfile(path, job.directory / "input.mp4")
            self.submit(job)
        except Exception:
            self.discard_upload(job)
            raise
        return job

    def close(self):
        with self.lock:
            self.closed = True
            for job in self.jobs.values():
                job.cancel.set()
        self.executor.shutdown(wait=True, cancel_futures=True)


class ConverterHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_close(self):
        super().server_close()
        self.state.close()


class Handler(BaseHTTPRequestHandler):
    server_version = "WallpaperConverter"

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, *_):
        # Request URLs can carry download capabilities. Do not log them.
        pass

    def _headers(self, status: int, mime: str, length: int, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; connect-src 'self'; style-src 'self'; script-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        if extra:
            for key, value in extra.items():
                self.send_header(key, value)
        self.end_headers()

    def _json(self, status: int, value):
        data = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self._headers(status, "application/json; charset=utf-8", len(data))
        if self.command != "HEAD":
            self.wfile.write(data)

    def _authority(self) -> bool:
        hosts = self.headers.get_all("Host", [])
        origins = self.headers.get_all("Origin", [])
        if len(hosts) != 1 or hosts[0] not in self.server.allowed_hosts or len(origins) > 1:
            return False
        return not origins or origins[0] == "http://" + hosts[0]

    def _authenticated(self) -> bool:
        values = self.headers.get_all("Authorization", [])
        return len(values) == 1 and hmac.compare_digest(values[0].encode("utf-8"), ("Bearer " + self.server.state.token).encode("utf-8"))

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not self._authority():
            return self._json(403, {"error": "origin_or_host_denied"})
        route = urlsplit(self.path)
        static = {"/": ("index.html", "text/html; charset=utf-8"),
                  "/app.js": ("app.js", "text/javascript; charset=utf-8"),
                  "/style.css": ("style.css", "text/css; charset=utf-8")}
        if route.path in static and not route.query:
            name, mime = static[route.path]
            data = (STATIC / name).read_bytes()
            self._headers(200, mime, len(data))
            if self.command != "HEAD":
                self.wfile.write(data)
            return
        if route.path == "/api/state" and not route.query:
            if not self._authenticated():
                return self._json(401, {"error": "authorization_required"})
            with self.server.state.lock:
                value = {"busy": self.server.state.active is not None, "defaults": DEFAULTS,
                         "jobs": [job.public() for job in reversed(list(self.server.state.jobs.values()))]}
            return self._json(200, value)
        match = re.fullmatch(r"/api/jobs/(" + UUID_PATTERN.pattern + r")/download", route.path)
        if match:
            values = parse_qs(route.query, keep_blank_values=True)
            with self.server.state.lock:
                job = self.server.state.jobs.get(match[1])
                permitted = job and job.state == "done" and job.output and set(values) == {"key"} and len(values["key"]) == 1 and hmac.compare_digest(values["key"][0].encode("utf-8"), job.download_key.encode("utf-8"))
            if not permitted:
                return self._json(404, {"error": "download_not_found"})
            size = job.output.stat().st_size
            etag = '"' + (job.sha256 or self.server.state._digest(job.output)) + '"'
            extra = {"Content-Disposition": "attachment; filename=\"wallpaper.tendies\"; filename*=UTF-8''" + quote(job.title + ".tendies", safe=""),
                     "Accept-Ranges": "bytes", "ETag": etag}
            ranges = self.headers.get_all("Range", [])
            if_ranges = self.headers.get_all("If-Range", [])
            start, end, status = 0, size - 1, 200
            if len(ranges) > 1 or len(if_ranges) > 1:
                self._headers(416, "application/octet-stream", 0, {**extra, "Content-Range": f"bytes */{size}"})
                return
            if ranges and (not if_ranges or if_ranges[0] == etag):
                requested = re.fullmatch(r"bytes=([0-9]{0,12})-([0-9]{0,12})", ranges[0])
                try:
                    if requested is None or not any(requested.groups()):
                        raise ValueError()
                    lower, upper = requested.groups()
                    if lower:
                        start = int(lower)
                        end = min(int(upper), size - 1) if upper else size - 1
                        if start >= size or end < start:
                            raise ValueError()
                    else:
                        suffix = int(upper)
                        if suffix <= 0:
                            raise ValueError()
                        start = max(0, size - suffix)
                    status = 206
                    extra["Content-Range"] = f"bytes {start}-{end}/{size}"
                except ValueError:
                    self._headers(416, "application/octet-stream", 0, {**extra, "Content-Range": f"bytes */{size}"})
                    return
            with job.output.open("rb") as stream:
                remaining = end - start + 1
                self._headers(status, "application/octet-stream", remaining, extra)
                if self.command == "HEAD":
                    return
                stream.seek(start)
                while remaining:
                    chunk = stream.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
            return
        self._json(404, {"error": "not_found"})

    def do_POST(self):
        self.close_connection = True
        if not self._authority():
            return self._json(403, {"error": "origin_or_host_denied"})
        if not self._authenticated():
            return self._json(401, {"error": "authorization_required"})
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get_all("Transfer-Encoding") or len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,12}", lengths[0]):
            return self._json(400, {"error": "content_length_required"})
        length = int(lengths[0])
        route = urlsplit(self.path)
        cancel = re.fullmatch(r"/api/jobs/(" + UUID_PATTERN.pattern + r")/cancel", route.path)
        if cancel and length == 0 and not route.query:
            with self.server.state.lock:
                job = self.server.state.jobs.get(cancel[1])
                active_job = job is not None and job.state in {"uploading", "queued", "converting"}
                if active_job:
                    job.cancel.set()
            return self._json(200 if job else 404, {"cancelled": bool(active_job)})
        if route.path != "/api/jobs":
            return self._json(404, {"error": "not_found"})
        if not 0 < length <= MAX_INPUT_BYTES:
            return self._json(413, {"error": "upload_size_limit"})
        try:
            title, options = options_from(route.query)
        except ValueError:
            return self._json(400, {"error": "invalid_options"})
        if shutil.disk_usage(self.server.state.root).free < length * 2 + 1024**3:
            return self._json(507, {"error": "insufficient_disk_space"})
        try:
            job = self.server.state.reserve(title, options)
        except RuntimeError as error:
            return self._json(409, {"error": "busy" if str(error) == "busy" else "job_history_full_use_another_data_directory"})
        try:
            with (job.directory / "input.mp4").open("xb") as output:
                remaining = length
                while remaining:
                    if shutil.disk_usage(self.server.state.root).free < remaining + 1024**3:
                        raise OSError("Disk space changed during upload")
                    if job.cancel.is_set():
                        raise ConnectionError("Upload cancelled")
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise ConnectionError("Incomplete upload")
                    output.write(chunk)
                    remaining -= len(chunk)
            self.server.state.submit(job)
        except Exception:
            self.server.state.discard_upload(job)
            return self._json(400, {"error": "upload_incomplete"})
        self._json(202, {"id": job.id, "state": "queued"})


def create_server(host: str, port: int, data_dir: Path, *, converter=None, token=None) -> ConverterHTTPServer:
    host = local_host(host)
    if converter is None:
        from local_converter import convert
        converter = convert
    server = ConverterHTTPServer((host, port), Handler)
    server.state = ConverterState(data_dir, converter, token)
    actual_port = server.server_address[1]
    server.allowed_hosts = {f"{host}:{actual_port}"}
    if ipaddress.ip_address(host).is_loopback:
        server.allowed_hosts.update({f"localhost:{actual_port}", f"127.0.0.1:{actual_port}"})
    return server


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=57351)
    parser.add_argument("--data-dir", type=Path, default=ROOT / "artifacts/ios-local-converter/data")
    parser.add_argument("--input", type=Path, help="Trusted local file to copy and convert at startup; never exposed as an HTTP path")
    parser.add_argument("--title", default="Wallpaper")
    args = parser.parse_args()
    server = create_server(args.host, args.port, args.data_dir)
    if args.input:
        job = server.state.enqueue_local(args.input, args.title)
        print("Queued local conversion " + job.id, flush=True)
    print(f"Local converter: http://{args.host}:{server.server_address[1]}/#token={server.state.token}", flush=True)
    print("Private LAN only; no remote URL imports, external upload, or automatic system wallpaper writes. Keep this console running.", flush=True)
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
