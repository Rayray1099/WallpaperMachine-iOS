#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Isolated loopback HTTP/security tests; fake conversion is not media/device proof."""
from __future__ import annotations

import http.client
from html.parser import HTMLParser
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from urllib.parse import parse_qs, quote, urlencode, urlsplit
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / "ios" / "serve_converter.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("ios_converter_server", SCRIPT)
server_module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = server_module
assert SPEC.loader is not None
SPEC.loader.exec_module(server_module)

# Synthetic upload bytes only: this suite tests HTTP transport/ownership, not a decoder.
UPLOAD = b"\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isommp42synthetic-input"
TOKEN = "test-only-local-capability-not-a-user-credential"
ARCHIVE_STREAM = io.BytesIO()
with zipfile.ZipFile(ARCHIVE_STREAM, "w") as archive:
    archive.writestr("transport-test.txt", "synthetic HTTP transport fixture")
ARCHIVE = ARCHIVE_STREAM.getvalue()


class FakeConverter:
    def __init__(self):
        self.started = threading.Event()
        self.release = threading.Event()
        self.release.set()
        self.calls = []
        self.error = None
        self.return_path = None

    def __call__(self, input_path, job_dir, *, title, progress, cancel_event, **options):
        self.calls.append({"input": Path(input_path), "job_dir": Path(job_dir),
                           "bytes": Path(input_path).read_bytes(), "title": title,
                           "options": options})
        progress({"stage": "decoding", "current": 7, "total": 10,
                  "output_bytes": 0, "path": "private/internal/path",
                  "stderr": "private diagnostic not for HTTP"})
        self.started.set()
        deadline = time.monotonic() + 5
        while not self.release.wait(0.01):
            if cancel_event.is_set():
                raise RuntimeError("private cancellation diagnostic")
            if time.monotonic() > deadline:
                raise RuntimeError("test worker timed out")
        if self.error:
            raise self.error
        if self.return_path is not None:
            return self.return_path
        output = Path(job_dir) / "output.tendies"
        output.write_bytes(ARCHIVE)
        return output


class IOSConverterHTTPTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="wm-ios-http-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.secret = self.root / "private.txt"
        self.secret.write_bytes(b"outside-owned-job-sentinel")
        self.data = self.root / "server-data"
        self.converter = FakeConverter()
        self.start_server()

    def start_server(self, token=TOKEN):
        self.server = server_module.create_server("127.0.0.1", 0, self.data,
                                                  converter=self.converter, token=token)
        self.token = self.server.state.token
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)
        self.port = self.server.server_address[1]
        self.authority = f"127.0.0.1:{self.port}"
        self.origin = "http://" + self.authority

    def close_server(self):
        if self.server is None:
            return
        self.converter.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        self.server = None

    def request(self, path, *, method="GET", body=None, auth=True, origin=None, headers=None):
        request_headers = dict(headers or {})
        if auth:
            request_headers["Authorization"] = "Bearer " + self.token
        if origin is not None:
            request_headers["Origin"] = origin
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.request(method, path, body=body, headers=request_headers)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def raw_request(self, method, path, headers, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
            for key, value in headers:
                connection.putheader(key, value)
            connection.endheaders(body)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def state(self):
        status, _, body = self.request("/api/state")
        self.assertEqual(status, 200)
        return json.loads(body)

    def upload(self, *, title="HTTP fixture", body=UPLOAD, query=None):
        query = urlencode({"title": title}) if query is None else query
        status, _, response = self.request("/api/jobs?" + query, method="POST", body=body,
                                           origin=self.origin,
                                           headers={"Content-Type": "application/octet-stream"})
        self.assertEqual(status, 202, response)
        return json.loads(response)["id"]

    def await_job(self, identifier, expected, timeout=3):
        deadline = time.monotonic() + timeout
        pause = threading.Event()
        while time.monotonic() < deadline:
            document = self.state()
            job = next((j for j in document["jobs"] if j["id"] == identifier), None)
            if job and job["state"] == expected and not document["busy"]:
                return job
            pause.wait(0.01)
        self.fail(f"Job did not reach {expected}: {document}")

    def test_state_requires_bearer_not_query_cookie_or_wrong_capability(self):
        for headers in ({}, {"Authorization": "Bearer wrong"},
                        {"Cookie": "token=" + TOKEN}):
            with self.subTest(headers=headers):
                self.assertEqual(self.request("/api/state", auth=False, headers=headers)[0], 401)
        self.assertNotEqual(self.request("/api/state?token=" + TOKEN, auth=False)[0], 200)
        self.assertEqual(self.state()["jobs"], [])

    def test_exact_host_and_optional_matching_origin_are_enforced(self):
        for host, origin in (("attacker.invalid", None), ("127.0.0.1:1", None),
                             (self.authority, "null"), (self.authority, "https://" + self.authority),
                             (self.authority, "http://attacker.invalid"),
                             (self.authority, self.origin + "/")):
            with self.subTest(host=host, origin=origin):
                self.assertEqual(self.request("/api/state", origin=origin,
                                              headers={"Host": host})[0], 403)
        self.assertEqual(self.request("/api/state", origin=self.origin)[0], 200)
        self.assertEqual(self.request("/api/state", headers={"Host": f"localhost:{self.port}"},
                                      origin=f"http://localhost:{self.port}")[0], 200)

    def test_duplicate_authority_origin_and_authorization_are_rejected(self):
        common = [("Host", self.authority), ("Authorization", "Bearer " + TOKEN)]
        for added, expected in (([("Host", self.authority)], 403),
                                ([("Origin", self.origin), ("Origin", self.origin)], 403),
                                ([("Authorization", "Bearer " + TOKEN)], 401)):
            with self.subTest(added=added):
                self.assertEqual(self.raw_request("GET", "/api/state", common + added)[0], expected)

    def test_auth_and_origin_are_checked_before_upload_body(self):
        for auth, origin, expected in ((False, self.origin, 401),
                                       (True, "http://attacker.invalid", 403)):
            headers = [("Host", self.authority), ("Origin", origin),
                       ("Content-Length", "1000000")]
            if auth:
                headers.append(("Authorization", "Bearer " + TOKEN))
            # Intentionally send none of the promised bytes: a safe rejection must not read them.
            self.assertEqual(self.raw_request("POST", "/api/jobs", headers)[0], expected)
        self.assertEqual(self.state()["jobs"], [])

    def test_ambiguous_invalid_missing_and_chunked_lengths_never_reserve_jobs(self):
        common = [("Host", self.authority), ("Authorization", "Bearer " + TOKEN)]
        cases = ([], [("Content-Length", "-1")], [("Content-Length", "+1")],
                 [("Content-Length", "1.0")], [("Content-Length", "1,1")],
                 [("Content-Length", "1"), ("Content-Length", "1")],
                 [("Content-Length", "1"), ("Content-Length", "2")],
                 [("Transfer-Encoding", "chunked")],
                 [("Content-Length", "1"), ("Transfer-Encoding", "chunked")])
        for added in cases:
            with self.subTest(headers=added):
                self.assertEqual(self.raw_request("POST", "/api/jobs", common + added)[0], 400)
        for length in ("0", str(2 * 1024**3 + 1)):
            with self.subTest(length=length):
                self.assertEqual(self.raw_request("POST", "/api/jobs", common +
                                                  [("Content-Length", length)])[0], 413)
        self.assertEqual(self.state()["jobs"], [])
        self.assertEqual(self.converter.calls, [])

    def test_unknown_duplicate_or_unbounded_options_are_rejected_before_body(self):
        for query in ("path=C%3A%5Cprivate.mp4", "url=http%3A%2F%2Fexample.invalid%2Fa.mp4",
                      "title=a&title=b", "fps=0", "fps=121", "fps=nan", "width=65",
                      "width=4096&height=4096", "quality=0", "duration=NaN", "duration=601",
                      "package_layout=modern", "package_layout=posterBoard27&package_layout=legacy"):
            with self.subTest(query=query):
                status, _, _ = self.raw_request("POST", "/api/jobs?" + query,
                    [("Host", self.authority), ("Authorization", "Bearer " + TOKEN),
                     ("Content-Length", "1000000")])
                self.assertEqual(status, 400)
        self.assertEqual(self.state()["jobs"], [])

    def test_low_disk_space_rejects_without_job_or_source_changes(self):
        usage = type("Usage", (), {"free": 0})()
        with mock.patch.object(server_module.shutil, "disk_usage", return_value=usage):
            status, _, _ = self.request("/api/jobs", method="POST", body=UPLOAD)
        self.assertEqual(status, 507)
        self.assertEqual(self.state()["jobs"], [])
        self.assertEqual(self.secret.read_bytes(), b"outside-owned-job-sentinel")

    def test_upload_runs_in_owned_directory_and_ignores_filename_header(self):
        query = urlencode({"title": "合成 fixture", "fps": 30, "width": 128,
                           "height": 256, "quality": 3, "duration": 0.5})
        status, _, body = self.request("/api/jobs?" + query, method="POST", body=UPLOAD,
            headers={"X-Filename": "../../private.txt", "Filename": "C:\\private.txt"})
        self.assertEqual(status, 202, body)
        identifier = json.loads(body)["id"]
        job = self.await_job(identifier, "done")
        call = self.converter.calls[0]
        self.assertEqual(call["bytes"], UPLOAD)
        self.assertEqual(call["title"], "合成 fixture")
        self.assertEqual(call["options"], {"fps": 30, "width": 128, "height": 256,
                                          "quality": 3, "duration": 0.5})
        self.assertEqual(call["job_dir"].resolve().parent, (self.data / "jobs").resolve())
        self.assertEqual(call["input"].parent, call["job_dir"])
        self.assertNotIn(str(self.root), json.dumps(job))
        self.assertEqual(self.secret.read_bytes(), b"outside-owned-job-sentinel")

    def test_explicit_30_and_60_fps_keep_native_full_length_options(self):
        for fps in (30, 60):
            with self.subTest(fps=fps):
                identifier = self.upload(query=urlencode({"title": "Selected cadence", "fps": fps,
                    "width": 1668, "height": 2420, "quality": 2}))
                self.await_job(identifier, "done")
                call = self.converter.calls[-1]
                self.assertEqual(call["options"], {"fps": fps, "width": 1668,
                                                   "height": 2420, "quality": 2})
                self.assertEqual(call["bytes"], UPLOAD)
                self.assertNotIn("duration", call["options"])

    def test_modern_package_layout_is_forwarded_and_persisted(self):
        identifier = self.upload(query=urlencode({"title": "Modern layout", "fps": 30,
                                                   "width": 1668, "height": 2420, "quality": 2,
                                                   "package_layout": "posterBoard27"}))
        job = self.await_job(identifier, "done")
        self.assertEqual(job["package_layout"], "posterBoard27")
        self.assertEqual(self.converter.calls[-1]["options"], {
            "fps": 30, "width": 1668, "height": 2420, "quality": 2,
            "package_layout": "posterBoard27"})
        receipt = json.loads((self.data / "jobs" / identifier / "completed.json").read_text(encoding="utf-8"))
        self.assertEqual(receipt["options"]["package_layout"], "posterBoard27")
        self.close_server()
        self.start_server(token=None)
        restored = self.state()["jobs"][0]
        self.assertEqual(restored["package_layout"], "posterBoard27")

    @unittest.skipUnless(os.environ.get("IOS_LOCAL_CONVERTER_INTEGRATION") == "1",
                         "Set IOS_LOCAL_CONVERTER_INTEGRATION=1 for CPU-only tiny fixture")
    def test_real_http_modern_layout_round_trip(self):
        # The HTTP server owns the upload; the real converter owns FFmpeg and the
        # Swift packager. This is archive/transport proof, not PosterBoard playback.
        from local_converter import _tool, convert

        self.server.state.converter = convert
        source = self.root / "http-modern.mp4"
        subprocess.run([str(_tool("ffmpeg")), "-nostdin", "-v", "error", "-n",
                        "-f", "lavfi", "-i", "color=c=green:s=64x96:r=60:d=0.05",
                        "-an", "-c:v", "mpeg4", "-threads", "1", str(source)],
                       check=True, stdin=subprocess.DEVNULL, timeout=20)
        identifier = self.upload(title="HTTP modern", body=source.read_bytes(),
                                 query=urlencode({"title": "HTTP modern", "fps": 60,
                                                  "width": 64, "height": 96, "quality": 2,
                                                  "package_layout": "posterBoard27"}))
        job = self.await_job(identifier, "done", timeout=120)
        self.assertEqual(job["package_layout"], "posterBoard27")
        status, _, body = self.request(job["download_url"], auth=False)
        self.assertEqual(status, 200)
        with zipfile.ZipFile(io.BytesIO(body)) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(len(archive.infolist()), 20)
            self.assertEqual(len([name for name in archive.namelist() if name.endswith(".jpg")]), 3)
            main = next(name for name in archive.namelist() if name.endswith("_Background-834w-1210h@2x~ipad.ca/main.caml"))
            self.assertTrue(archive.read(main).lstrip().startswith(b"<?xml"))

    def test_browser_defaults_to_visible_30fps_without_removing_60fps(self):
        class FrameRatePicker(HTMLParser):
            def __init__(self):
                super().__init__()
                self.in_picker = False
                self.options = []

            def handle_starttag(self, tag, attrs):
                attrs = dict(attrs)
                if tag == "select":
                    self.in_picker = attrs.get("id") == "fps"
                elif tag == "option" and self.in_picker:
                    self.options.append((attrs.get("value"), "selected" in attrs))

            def handle_endtag(self, tag):
                if tag == "select":
                    self.in_picker = False

        status, _, body = self.request("/", auth=False)
        self.assertEqual(status, 200)
        parser = FrameRatePicker()
        parser.feed(body.decode("utf-8"))
        selected = [value for value, explicit in parser.options if explicit]
        self.assertEqual(selected or [parser.options[0][0]], ["30"])
        self.assertIn("60", [value for value, _ in parser.options])

    def test_one_active_conversion_blocks_second_upload_without_overwrite(self):
        self.converter.release.clear()
        first = self.upload()
        self.assertTrue(self.converter.started.wait(2))
        status, _, body = self.raw_request("POST", "/api/jobs", [
            ("Host", self.authority), ("Authorization", "Bearer " + TOKEN),
            ("Content-Length", "1000000")])
        self.assertEqual(status, 409, body)
        document = self.state()
        self.assertTrue(document["busy"])
        self.assertEqual([job["id"] for job in document["jobs"]], [first])
        self.assertEqual(len(self.converter.calls), 1)
        self.assertNotIn("stderr", json.dumps(document))
        self.assertNotIn("private/internal/path", json.dumps(document))
        self.converter.release.set()
        self.await_job(first, "done")
        second = self.upload(title="Second")
        self.assertNotEqual(first, second)
        self.await_job(second, "done")
        self.assertEqual(len(self.converter.calls), 2)

    def test_truncated_upload_cleans_only_its_owned_directory_and_releases_slot(self):
        unrelated = self.data / "jobs" / "operator-keep.txt"
        unrelated.write_bytes(b"keep me")
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        connection.putrequest("POST", "/api/jobs")
        connection.putheader("Authorization", "Bearer " + TOKEN)
        connection.putheader("Content-Length", "10000")
        connection.endheaders(b"short")
        connection.sock.shutdown(socket.SHUT_WR)
        response = connection.getresponse()
        self.assertEqual(response.status, 400)
        response.read()
        connection.close()
        self.assertFalse(self.state()["busy"])
        self.assertEqual(self.state()["jobs"], [])
        self.assertEqual(list((self.data / "jobs").iterdir()), [unrelated])
        self.assertEqual(unrelated.read_bytes(), b"keep me")
        self.assertEqual(self.converter.calls, [])
        self.await_job(self.upload(), "done")

    def test_upload_itself_reserves_the_only_slot_before_conversion_starts(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        self.addCleanup(connection.close)
        connection.putrequest("POST", "/api/jobs?title=Partial")
        connection.putheader("Authorization", "Bearer " + TOKEN)
        connection.putheader("Content-Length", "10000")
        connection.endheaders(b"short")
        deadline = time.monotonic() + 2
        pause = threading.Event()
        while time.monotonic() < deadline:
            document = self.state()
            if document["busy"]:
                break
            pause.wait(0.01)
        self.assertTrue(document["busy"])
        self.assertEqual(document["jobs"][0]["state"], "uploading")
        self.assertEqual(self.converter.calls, [])
        status, _, _ = self.raw_request("POST", "/api/jobs?title=Second", [
            ("Host", self.authority), ("Authorization", "Bearer " + TOKEN),
            ("Content-Length", "10000")])
        self.assertEqual(status, 409)
        connection.sock.shutdown(socket.SHUT_WR)
        response = connection.getresponse()
        self.assertEqual(response.status, 400)
        response.read()
        self.assertFalse(self.state()["busy"])
        self.assertEqual(self.state()["jobs"], [])

    def test_disk_loss_during_upload_discards_only_new_job_and_releases_slot(self):
        unrelated = self.data / "jobs" / "operator-keep.txt"
        unrelated.write_bytes(b"keep me")
        ample = type("Usage", (), {"free": 10 * 1024**3})()
        depleted = type("Usage", (), {"free": 0})()
        with mock.patch.object(server_module.shutil, "disk_usage", side_effect=[ample, depleted]):
            status, _, body = self.request("/api/jobs?title=Disk", method="POST", body=UPLOAD)
        self.assertEqual(status, 400, body)
        self.assertFalse(self.state()["busy"])
        self.assertEqual(self.state()["jobs"], [])
        self.assertEqual(list((self.data / "jobs").iterdir()), [unrelated])
        self.assertEqual(unrelated.read_bytes(), b"keep me")
        self.assertEqual(self.converter.calls, [])

    def test_public_static_assets_have_no_capability_or_cross_origin_permissions(self):
        for path, kind in (("/", "text/html"), ("/app.js", "text/javascript"),
                           ("/style.css", "text/css")):
            with self.subTest(path=path):
                status, headers, body = self.request(path, auth=False)
                self.assertEqual(status, 200)
                self.assertTrue(headers["Content-Type"].startswith(kind))
                self.assertNotIn(TOKEN.encode(), body)
                self.assertEqual(headers["Cache-Control"], "no-store")
                self.assertEqual(headers["Referrer-Policy"], "no-referrer")
                self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
                self.assertNotIn("Access-Control-Allow-Origin", headers)
        self.assertEqual(self.request("/app.js", auth=False,
                                      origin="http://attacker.invalid")[0], 403)

    def test_invalid_local_source_never_reserves_job_or_changes_original(self):
        empty = self.root / "empty.mp4"
        empty.write_bytes(b"")
        disguised = self.root / "source.txt"
        disguised.write_bytes(UPLOAD)
        from local_converter import ConverterError
        for source in (empty, disguised):
            with self.subTest(source=source), self.assertRaises((ValueError, ConverterError)):
                self.server.state.enqueue_local(source, "Rejected")
        self.assertEqual(empty.read_bytes(), b"")
        self.assertEqual(disguised.read_bytes(), UPLOAD)
        self.assertEqual(self.state()["jobs"], [])
        self.assertEqual(self.converter.calls, [])

    def test_cancel_releases_worker_without_exposing_private_exception(self):
        self.converter.release.clear()
        identifier = self.upload()
        self.assertTrue(self.converter.started.wait(2))
        status, _, body = self.request(f"/api/jobs/{identifier}/cancel", method="POST", body=b"")
        self.assertEqual(status, 200, body)
        job = self.await_job(identifier, "cancelled")
        self.assertNotIn("private", json.dumps(job))
        self.assertNotIn("download_url", job)
        self.converter.release.set()
        self.await_job(self.upload(), "done")

    def test_cancel_requires_authenticated_empty_body_and_known_job(self):
        self.converter.release.clear()
        identifier = self.upload()
        self.assertTrue(self.converter.started.wait(2))
        path = f"/api/jobs/{identifier}/cancel"
        self.assertEqual(self.request(path, method="POST", body=b"", auth=False)[0], 401)
        self.assertEqual(self.request(path, method="POST", body=b"",
                                      origin="http://attacker.invalid")[0], 403)
        self.assertNotEqual(self.request(path, method="POST", body=b"not empty")[0], 200)
        self.assertEqual(self.request("/api/jobs/00000000-0000-0000-0000-000000000000/cancel",
                                      method="POST", body=b"")[0], 404)
        self.assertTrue(self.state()["busy"])
        self.converter.release.set()
        self.await_job(identifier, "done")

    def test_worker_failure_is_bounded_and_outside_output_cannot_be_downloaded(self):
        self.converter.error = RuntimeError("private stderr C:\\operator\\private.mp4")
        failed = self.await_job(self.upload(), "failed")
        self.assertEqual(failed["error"], "conversion_failed")
        self.assertNotIn("private", json.dumps(failed))
        self.assertNotIn("download_url", failed)
        self.converter.error = None
        self.converter.return_path = self.secret
        outside = self.await_job(self.upload(), "failed")
        self.assertNotIn("download_url", outside)
        self.assertEqual(self.secret.read_bytes(), b"outside-owned-job-sentinel")

    def test_download_uses_distinct_per_job_key_not_global_bearer(self):
        first = self.await_job(self.upload(), "done")
        second = self.await_job(self.upload(title="Second"), "done")
        download = first["download_url"]
        self.assertNotIn(TOKEN, download)
        first_key = parse_qs(urlsplit(download).query)["key"][0]
        second_key = parse_qs(urlsplit(second["download_url"]).query)["key"][0]
        self.assertNotEqual(first_key, second_key)
        path = urlsplit(download).path
        for suffix in ("", "?key=" + TOKEN, "?key=wrong", "?key=" + second_key,
                       "?key=" + first_key + "&key=" + first_key,
                       "?key=" + first_key + "&path=private.txt"):
            with self.subTest(suffix=suffix):
                self.assertEqual(self.request(path + suffix, auth=False)[0], 404)
        status, headers, body = self.request(download, auth=False)
        self.assertEqual(status, 200)
        self.assertEqual(body, ARCHIVE)
        self.assertEqual(headers["Content-Type"], "application/octet-stream")
        self.assertEqual(int(headers["Content-Length"]), len(ARCHIVE))
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertNotIn("Access-Control-Allow-Origin", headers)
        self.assertEqual(self.request(download, auth=False, origin="null")[0], 403)

    def test_download_head_returns_full_metadata_without_response_body(self):
        job = self.await_job(self.upload(), "done")
        path = job["download_url"]
        status, get_headers, body = self.request(path, auth=False)
        self.assertEqual((status, body), (200, ARCHIVE))
        status, headers, body = self.request(path, method="HEAD", auth=False)
        self.assertEqual((status, body), (200, b""))
        for key in ("Content-Length", "Content-Type", "Content-Disposition", "ETag"):
            self.assertEqual(headers[key], get_headers[key])
        self.assertEqual(int(headers["Content-Length"]), len(ARCHIVE))
        self.assertEqual(headers["Accept-Ranges"], "bytes")
        self.assertTrue(headers["ETag"].startswith('"') and headers["ETag"].endswith('"'))
        self.assertFalse(headers["ETag"].startswith("W/"))

    def test_single_byte_and_bounded_download_ranges_are_inclusive(self):
        job = self.await_job(self.upload(), "done")
        path = job["download_url"]
        _, full_headers, _ = self.request(path, method="HEAD", auth=False)
        for start, end in ((0, 0), (0, 7), (3, 11), (len(ARCHIVE) - 1, len(ARCHIVE) - 1)):
            with self.subTest(start=start, end=end):
                status, headers, body = self.request(path, auth=False,
                    headers={"Range": f"bytes={start}-{end}"})
                self.assertEqual(status, 206)
                self.assertEqual(body, ARCHIVE[start:end + 1])
                self.assertEqual(int(headers["Content-Length"]), end - start + 1)
                self.assertEqual(headers["Content-Range"], f"bytes {start}-{end}/{len(ARCHIVE)}")
                self.assertEqual(headers["ETag"], full_headers["ETag"])
                self.assertEqual(headers["Accept-Ranges"], "bytes")

    def test_open_ended_suffix_and_overlong_end_download_ranges_are_bounded(self):
        job = self.await_job(self.upload(), "done")
        cases = (("bytes=7-", 7, len(ARCHIVE) - 1),
                 ("bytes=-7", len(ARCHIVE) - 7, len(ARCHIVE) - 1),
                 ("bytes=-99999", 0, len(ARCHIVE) - 1),
                 ("bytes=0-99999", 0, len(ARCHIVE) - 1))
        for value, start, end in cases:
            with self.subTest(range=value):
                status, headers, body = self.request(job["download_url"], auth=False,
                                                    headers={"Range": value})
                self.assertEqual(status, 206)
                self.assertEqual(body, ARCHIVE[start:end + 1])
                self.assertEqual(int(headers["Content-Length"]), len(body))
                self.assertEqual(headers["Content-Range"], f"bytes {start}-{end}/{len(ARCHIVE)}")

    def test_invalid_multiple_and_unsatisfiable_download_ranges_return_416(self):
        job = self.await_job(self.upload(), "done")
        cases = ("bytes=", "bytes=-", "bytes=-0", "bytes=9-2", "bytes=abc-def",
                 "bytes=0-1,4-5", "items=0-1", f"bytes={len(ARCHIVE)}-",
                 "bytes=999999999999999999999999999999999999-", "bytes=+1-3")
        for value in cases:
            with self.subTest(range=value):
                status, headers, body = self.request(job["download_url"], auth=False,
                                                    headers={"Range": value})
                self.assertEqual(status, 416)
                self.assertEqual(headers["Content-Range"], f"bytes */{len(ARCHIVE)}")
                self.assertNotEqual(body, ARCHIVE)
                self.assertNotIn(ARCHIVE, body)
        status, _, _ = self.raw_request("GET", job["download_url"], [
            ("Host", self.authority), ("Range", "bytes=0-1"), ("Range", "bytes=2-3")])
        self.assertEqual(status, 416)

    def test_head_and_range_downloads_keep_capability_and_origin_checks(self):
        job = self.await_job(self.upload(), "done")
        download = job["download_url"]
        bare = urlsplit(download).path
        for method in ("GET", "HEAD"):
            for path in (bare, bare + "?key=wrong", bare + "?key=" + TOKEN):
                with self.subTest(method=method, path=path):
                    status, _, body = self.request(path, method=method, auth=False,
                                                   headers={"Range": "bytes=0-7"})
                    self.assertEqual(status, 404)
                    if method == "HEAD":
                        self.assertEqual(body, b"")
            with self.subTest(method=method, origin="null"):
                status, _, body = self.request(download, method=method, auth=False, origin="null",
                                               headers={"Range": "bytes=0-7"})
                self.assertEqual(status, 403)
                if method == "HEAD":
                    self.assertEqual(body, b"")

    def test_resumed_download_reconstructs_archive_and_checks_if_range_etag(self):
        job = self.await_job(self.upload(), "done")
        download = job["download_url"]
        _, headers, _ = self.request(download, method="HEAD", auth=False)
        etag = headers["ETag"]
        cut = len(ARCHIVE) // 2
        status, _, prefix = self.request(download, auth=False,
            headers={"Range": f"bytes=0-{cut - 1}", "If-Range": etag})
        self.assertEqual(status, 206)
        status, _, suffix = self.request(download, auth=False,
            headers={"Range": f"bytes={cut}-", "If-Range": etag})
        self.assertEqual(status, 206)
        self.assertEqual(prefix + suffix, ARCHIVE)
        for validator in ('"different-archive"', "W/" + etag, "Sun, 06 Nov 1994 08:49:37 GMT"):
            with self.subTest(validator=validator):
                status, headers, body = self.request(download, auth=False,
                    headers={"Range": f"bytes={cut}-", "If-Range": validator})
                self.assertEqual(status, 200)
                self.assertEqual(body, ARCHIVE)
                self.assertNotIn("Content-Range", headers)

    def test_utf8_and_control_characters_cannot_inject_download_headers(self):
        title = '合成 "title"\r\nX-Injected: yes'
        job = self.await_job(self.upload(title=title), "done")
        status, headers, _ = self.request(job["download_url"], auth=False)
        self.assertEqual(status, 200)
        self.assertNotIn("X-Injected", headers)
        disposition = headers["Content-Disposition"]
        self.assertTrue(disposition.startswith('attachment; filename="wallpaper.tendies";'))
        self.assertIn("filename*=UTF-8''" + quote(job["title"] + ".tendies", safe=""), disposition)
        self.assertNotIn("\r", disposition)
        self.assertNotIn("\n", disposition)

    def test_non_ascii_capabilities_fail_as_http_errors_not_handler_crashes(self):
        status, _, _ = self.request("/api/state", auth=False,
                                    headers={"Authorization": "Bearer \u00e9"})
        self.assertEqual(status, 401)
        job = self.await_job(self.upload(), "done")
        path = urlsplit(job["download_url"]).path
        self.assertEqual(self.request(path + "?key=%C3%A9", auth=False)[0], 404)

    def test_static_whitelist_never_serves_server_data_or_arbitrary_paths(self):
        for path in ("/../private.txt", "/%2e%2e/private.txt", "/scripts/ios/serve_converter.py",
                     "/jobs", "/data", "/api/fetch?url=http://example.invalid/",
                     "/api/state?path=" + quote(str(self.secret)), "/?token=" + TOKEN):
            with self.subTest(path=path):
                status, _, body = self.request(path)
                self.assertEqual(status, 404)
                self.assertNotIn(b"outside-owned-job-sentinel", body)
        for path in ("/api/fetch", "/api/local", "/api/jobs/../../private/cancel"):
            self.assertEqual(self.request(path, method="POST", body=b"")[0], 404)
        self.assertEqual(self.converter.calls, [])

    def test_completed_job_survives_restart_with_fresh_boot_and_download_capabilities(self):
        original = self.await_job(self.upload(title="Persistent 合成"), "done")
        original_token = self.token
        original_url = original["download_url"]
        self.close_server()
        self.start_server(token=None)
        self.assertNotEqual(self.token, original_token)
        self.assertEqual(self.request("/api/state", auth=False,
            headers={"Authorization": "Bearer " + original_token})[0], 401)
        document = self.state()
        self.assertFalse(document["busy"])
        self.assertEqual(len(document["jobs"]), 1)
        restored = document["jobs"][0]
        self.assertEqual(restored["id"], original["id"])
        self.assertEqual(restored["title"], original["title"])
        self.assertEqual(restored["state"], "done")
        self.assertNotEqual(restored["download_url"], original_url)
        self.assertEqual(self.request(original_url, auth=False)[0], 404)
        self.assertEqual(self.request(restored["download_url"], auth=False)[2], ARCHIVE)
        self.assertEqual(len(self.converter.calls), 1, "Restart must not reconvert or read originals")
        self.assertNotIn(str(self.root), json.dumps(document))

    def test_square_pixel_assumption_is_public_boolean_and_survives_completion_and_restart(self):
        original_converter = self.server.state.converter
        self.converter.release.clear()
        def report_assumption(input_path, job_dir, *, progress, **kwargs):
            def with_assumption(event):
                progress({**event, "sample_aspect_ratio_assumed": True,
                          "sample_aspect_ratio": "PRIVATE_RAW_SAR_OR_PATH"})
            return original_converter(input_path, job_dir, progress=with_assumption, **kwargs)
        self.server.state.converter = report_assumption
        identifier = self.upload(title="Unspecified sample aspect")
        self.assertTrue(self.converter.started.wait(2))
        active = self.state()["jobs"][0]
        self.assertEqual(active["id"], identifier)
        self.assertIs(active["sample_aspect_ratio_assumed"], True)
        self.assertNotIn("sample_aspect_ratio", active["progress"])
        self.assertNotIn("PRIVATE_RAW_SAR_OR_PATH", json.dumps(active))
        self.converter.release.set()
        completed = self.await_job(identifier, "done")
        self.assertIs(completed["sample_aspect_ratio_assumed"], True)
        self.close_server()
        receipt_path = self.data / "jobs" / identifier / "completed.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        self.assertIs(receipt["sample_aspect_ratio_assumed"], True)
        self.assertNotIn("PRIVATE_RAW_SAR_OR_PATH", json.dumps(receipt))
        self.start_server(token=None)
        restored = self.state()["jobs"][0]
        self.assertEqual(restored["id"], identifier)
        self.assertIs(restored["sample_aspect_ratio_assumed"], True)
        self.assertEqual(self.request(restored["download_url"], auth=False)[2], ARCHIVE)

    def test_non_boolean_sample_aspect_receipts_are_ignored_without_deleting_archives(self):
        original = self.await_job(self.upload(), "done")
        self.assertIs(original["sample_aspect_ratio_assumed"], False)
        self.close_server()
        original_receipt = self.data / "jobs" / original["id"] / "completed.json"
        valid = json.loads(original_receipt.read_text(encoding="utf-8"))
        invalid_outputs = []
        for index, invalid in enumerate(("true", "false", 1, 0, None, [], {}), 1):
            directory = self.data / "jobs" / f"00000000-0000-0000-0000-{index:012x}"
            directory.mkdir()
            output = directory / "output.tendies"
            output.write_bytes(ARCHIVE)
            value = {**valid, "id": directory.name, "sample_aspect_ratio_assumed": invalid}
            (directory / "completed.json").write_text(json.dumps(value), encoding="utf-8")
            invalid_outputs.append(output)
        # Older completed receipts intentionally lack this optional field.
        valid.pop("sample_aspect_ratio_assumed", None)
        original_receipt.write_text(json.dumps(valid), encoding="utf-8")
        self.start_server(token=None)
        restored = self.state()["jobs"]
        self.assertEqual([job["id"] for job in restored], [original["id"]])
        self.assertIs(restored[0]["sample_aspect_ratio_assumed"], False)
        for output in invalid_outputs:
            self.assertEqual(output.read_bytes(), ARCHIVE)

    def test_restart_ignores_interrupted_and_tampered_outputs_without_deleting_them(self):
        first = self.await_job(self.upload(title="Changed bytes"), "done")
        second = self.await_job(self.upload(title="Missing receipt"), "done")
        third = self.await_job(self.upload(title="Changed length"), "done")
        self.close_server()
        first_output = self.data / "jobs" / first["id"] / "output.tendies"
        first_output.write_bytes(b"X" + ARCHIVE[1:])  # Same length, different hash.
        second_receipt = self.data / "jobs" / second["id"] / "completed.json"
        second_receipt.unlink()
        third_output = self.data / "jobs" / third["id"] / "output.tendies"
        third_output.write_bytes(ARCHIVE + b"extra")
        self.start_server(token=None)
        self.assertEqual(self.state()["jobs"], [])
        self.assertEqual(first_output.read_bytes(), b"X" + ARCHIVE[1:])
        self.assertEqual(third_output.read_bytes(), ARCHIVE + b"extra")
        self.assertTrue((second_receipt.parent / "output.tendies").is_file())

    def test_malformed_or_foreign_completion_receipts_do_not_break_startup(self):
        original = self.await_job(self.upload(), "done")
        self.close_server()
        folder = self.data / "jobs" / original["id"]
        receipt = folder / "completed.json"
        valid = json.loads(receipt.read_text(encoding="utf-8"))
        malformed = [[], None, "not-an-object", {}, {**valid, "options": []},
                     {**valid, "options": None}, {**valid, "title": []},
                     {**valid, "id": "00000000-0000-0000-0000-000000000000"},
                     {**valid, "sha256": None}, {**valid, "schema": 999}]
        for index, document in enumerate(malformed, 1):
            directory = self.data / "jobs" / f"00000000-0000-0000-0000-{index:012x}"
            directory.mkdir()
            (directory / "output.tendies").write_bytes(ARCHIVE)
            value = document
            if isinstance(document, dict) and document.get("id") == original["id"]:
                value = {**document, "id": directory.name}
            (directory / "completed.json").write_text(json.dumps(value), encoding="utf-8")
        foreign = self.data / "jobs" / "not-a-uuid"
        foreign.mkdir()
        (foreign / "output.tendies").write_bytes(ARCHIVE)
        (foreign / "completed.json").write_text(json.dumps(valid), encoding="utf-8")
        self.start_server(token=None)
        self.assertEqual([job["id"] for job in self.state()["jobs"]], [original["id"]])
        self.assertEqual((foreign / "output.tendies").read_bytes(), ARCHIVE)

    def test_cancel_during_completion_receipt_cannot_resurrect_after_restart(self):
        original_save = self.server.state._save_completed
        def cancel_while_saving(job, output):
            # Deterministic stand-in for cancellation arriving during a large hash/write.
            original_save(job, output)
            job.cancel.set()
        with mock.patch.object(self.server.state, "_save_completed", side_effect=cancel_while_saving):
            job = self.await_job(self.upload(), "cancelled")
        self.assertNotIn("download_url", job)
        self.close_server()
        self.start_server(token=None)
        self.assertEqual(self.state()["jobs"], [])

    def test_fixed_output_path_is_required_even_for_files_inside_job_directory(self):
        def wrong_output(input_path, job_dir, **kwargs):
            return input_path
        self.server.state.converter = wrong_output
        failed = self.await_job(self.upload(), "failed")
        self.assertNotIn("download_url", failed)
        self.assertTrue((self.data / "jobs" / failed["id"] / "input.mp4").is_file())
        self.assertFalse((self.data / "jobs" / failed["id"] / "completed.json").exists())

    def test_local_operator_enqueue_copies_source_and_preserves_original(self):
        source = self.root / "original.mp4"
        source.write_bytes(UPLOAD)
        job = self.server.state.enqueue_local(source, "Local copy", fps=30)
        self.await_job(job.id, "done")
        self.assertEqual(source.read_bytes(), UPLOAD)
        call = self.converter.calls[0]
        self.assertNotEqual(call["input"], source)
        self.assertEqual(call["bytes"], UPLOAD)


class IOSConverterBindTests(unittest.TestCase):
    def test_only_specific_loopback_or_rfc1918_addresses_are_accepted_without_binding(self):
        for host in ("127.0.0.1", "127.0.0.2", "192.168.2.200", "10.1.2.3", "172.16.0.1"):
            with self.subTest(host=host):
                self.assertEqual(server_module.local_host(host), host)
        for host in ("0.0.0.0", "::", "::1", "8.8.8.8", "169.254.1.1", "192.0.2.1",
                     "172.32.0.1", "localhost", "example.invalid"):
            with self.subTest(host=host), self.assertRaises(ValueError):
                server_module.local_host(host)


if __name__ == "__main__":
    unittest.main()
