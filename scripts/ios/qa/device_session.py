#!/usr/bin/env python3
"""Safe iCTRL session: schema-checked calls, explicit error handling, no double acts.

Safety rules this module enforces:

* A JSON-RPC ``error`` is an error even when HTTP status is 200; the official
  client returns the envelope without raising, so every response is inspected.
* A timeout is ambiguous, not a failure. The action may have run on the device.
  The session records the ambiguity, refuses further mutating actions until it is
  resolved, and resolves it only by reading ``logs`` for
  ``⏱ ✓ <method>`` — never by sending the action again. A retried tap fires twice.
* Non-200 HTTP, a missing cached credential and a MAC mismatch are distinct
  errors with distinct recovery advice; none of them is retried automatically.
* Request parameters and result shapes are validated against the captured schema
  before and after every call.
"""
from __future__ import annotations

import base64
import binascii
from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import socket
import time
from typing import Any, Callable

try:
    from . import schema_contract
    from .evidence import EvidenceRun, Stopwatch
    from .png_image import PNGError, PNGImage, decode_png
except ImportError:  # pragma: no cover - direct script import
    import schema_contract  # type: ignore[no-redef]
    from evidence import EvidenceRun, Stopwatch  # type: ignore[no-redef]
    from png_image import PNGError, PNGImage, decode_png  # type: ignore[no-redef]

MIN_TIMEOUT = 30.0
MUTATING_METHODS = frozenset({
    "tap", "double_tap", "long_press", "swipe", "drag", "type", "clear_text",
    "page", "scroll", "collect", "scroll_to_element", "tap_element", "find_and_tap",
    "launch_app", "activate_app", "terminate_app", "open_url", "home", "lock",
    "unlock", "reset", "config", "wait",
})
READ_ONLY_METHODS = frozenset({
    "device_info", "logs", "page_source", "screenshot", "find_element",
    "resolve_app", "list_apps", "is_locked", "screen_text",
})
TIMEOUT_MARK = "\u23f1"
COMPLETED_MARK = "\u2713"


class DeviceError(RuntimeError):
    """Base class for a live-device problem."""


class DeviceUnreachable(DeviceError):
    """The runner is not answering; nothing was sent successfully."""


class AuthenticationError(DeviceError):
    """The cached credential is missing, denied or expired; the Lead must re-pair."""


class ProtocolError(DeviceError):
    """The response violated JSON-RPC or the captured schema."""


class RpcError(DeviceError):
    """The device returned a JSON-RPC error object."""

    def __init__(self, code: int | None, message: str, data: Any = None):
        self.code = code
        self.message = message
        self.data = data
        super().__init__(f"JSON-RPC error {code}: {message}")


class AmbiguousOutcome(DeviceError):
    """A call timed out; the device may or may not have performed it."""

    def __init__(self, method: str, cause: str, mutating: bool):
        self.method = method
        self.cause = cause
        self.mutating = mutating
        super().__init__(
            f"{method} timed out ({cause}); outcome unknown. Do not resend it: "
            f"check logs for {method!r} with resolve_timeout() first")


class PendingAmbiguity(DeviceError):
    """A previous timeout is unresolved, so another mutating action is unsafe."""


@dataclass(frozen=True)
class PendingTimeout:
    method: str
    mutating: bool
    cause: str
    at: datetime


@dataclass(frozen=True)
class TimeoutResolution:
    status: str  # completed | timed_out | unknown | not_pending
    method: str
    lines: list[str]
    polls: int
    note: str = ""


@dataclass(frozen=True)
class Screenshot:
    path: Path
    sha256: str
    bytes_written: int
    format: str
    pixel_width: int
    pixel_height: int
    point_width: int
    point_height: int
    scale: float
    image: PNGImage
    capture_ms: float


def _is_timeout(error: BaseException) -> bool:
    import urllib.error

    if isinstance(error, (TimeoutError, socket.timeout)):
        return True
    if isinstance(error, urllib.error.URLError):
        reason = error.reason
        return (isinstance(reason, (TimeoutError, socket.timeout)) or
                "timed out" in str(reason).lower())
    return False


def _is_unreachable(error: BaseException) -> bool:
    import urllib.error

    if isinstance(error, (ConnectionError, urllib.error.URLError)):
        reason = getattr(error, "reason", error)
        return isinstance(reason, (ConnectionError, OSError))
    return False


def _translate_system_exit(error: SystemExit) -> DeviceError:
    text = str(error) or "official client exited without a message"
    code_match = re.search(r"rpc failed \((\d{3})\)", text)
    code = int(code_match.group(1)) if code_match else None
    if "no token" in text:
        return AuthenticationError(
            f"{text}; the Lead must pair the device again (never retry from QA)")
    if code in (401, 403):
        return AuthenticationError(f"{text}; pairing/authorization is required")
    if "MAC mismatch" in text:
        return ProtocolError(f"{text}; refusing the response")
    if code is not None:
        return RpcError(code, text)
    return DeviceError(text)


def is_mutating(method: str) -> bool:
    """Unknown methods are treated as mutating so they are never blindly retried."""
    if method in READ_ONLY_METHODS:
        return False
    if method in MUTATING_METHODS:
        return True
    return True


def _safe_summary(device_info: dict) -> dict:
    """A device_info subset safe to keep in evidence (no identifiers or secrets)."""
    keep = ("device_name", "model", "name", "system_name", "system_version",
            "point_width", "point_height", "pixel_width", "pixel_height", "scale",
            "server_version", "protocol_version", "skill_version", "capabilities")
    summary = {key: device_info[key] for key in keep if key in device_info}
    system = device_info.get("system")
    if isinstance(system, dict):
        summary["system"] = {
            key: system[key]
            for key in ("screen_locked", "foreground_app", "foreground_is_browser",
                        "thermal_state", "battery_state", "low_power_mode")
            if key in system
        }
    return summary


def _screenshot_meta(result: dict) -> dict:
    return {
        "format": result.get("format"),
        "pixel_width": int(result.get("pixel_width", 0)),
        "pixel_height": int(result.get("pixel_height", 0)),
        "point_width": int(result.get("point_width", 0)),
        "point_height": int(result.get("point_height", 0)),
        "scale": float(result.get("scale", 0)),
    }


class DeviceSession:
    """One schema-checked iCTRL session bound to a host and an evidence run."""

    def __init__(self, client: Any, schema: schema_contract.Schema, host: str,
                 evidence: EvidenceRun | None = None, *,
                 timeout: float = 45.0, log_timeout: float = 25.0,
                 sleep: Callable[[float], None] = time.sleep):
        if timeout < MIN_TIMEOUT:
            raise ValueError(f"client timeout must be >= {MIN_TIMEOUT:.0f}s")
        self.client = client
        self.schema = schema
        self.host = host
        self.evidence = evidence or EvidenceRun.create("session")
        self.timeout = timeout
        self.log_timeout = log_timeout
        self._sleep = sleep
        self.pending: PendingTimeout | None = None
        self.pending_warnings: list[str] = []
        self.calls: list[dict] = []

    # ------------------------------------------------------------- invocation
    def invoke(self, method: str, params: dict | None = None, *,
               timeout: float | None = None, mutating: bool | None = None) -> dict:
        """Validate, send and validate one call. Never retries."""
        params = {} if params is None else params
        acts = is_mutating(method) if mutating is None else mutating
        if self.pending is not None and acts:
            raise PendingAmbiguity(
                f"previous {self.pending.method!r} timed out and is unresolved; "
                "resolve it with logs before another action")

        issues = self.schema.check_request(method, params)
        if issues:
            raise ProtocolError("; ".join(issues))

        stopwatch = Stopwatch()
        try:
            response = self.client.call(
                self.host, method, params, timeout=timeout or self.timeout)
        except SystemExit as error:
            translated = _translate_system_exit(error)
            self._record(method, params, stopwatch, error=str(translated))
            raise translated from error
        except BaseException as error:  # noqa: BLE001 - transport translation is the point
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            if _is_timeout(error):
                self.pending = PendingTimeout(
                    method=method, mutating=acts, cause=str(error),
                    at=datetime.now(timezone.utc))
                self._record(method, params, stopwatch, error=f"timeout: {error}")
                raise AmbiguousOutcome(method, str(error), acts) from error
            if _is_unreachable(error):
                translated = DeviceUnreachable(
                    f"iCTRL runner at {self.host} is unreachable ({error}); "
                    "no UI action can be assumed to have run")
                self._record(method, params, stopwatch, error=str(translated))
                raise translated from error
            if isinstance(error, json.JSONDecodeError):
                translated = ProtocolError(f"{method}: response was not JSON: {error}")
                self._record(method, params, stopwatch, error=str(translated))
                raise translated from error
            translated = DeviceError(f"{method}: {type(error).__name__}: {error}")
            self._record(method, params, stopwatch, error=str(translated))
            raise translated from error

        duration = stopwatch.elapsed_ms()
        if not isinstance(response, dict):
            message = f"{method}: response must be a JSON object, got {type(response).__name__}"
            self._record(method, params, stopwatch, error=message)
            raise ProtocolError(message)
        if "error" in response:
            error = response["error"]
            data = error.get("data") if isinstance(error, dict) else None
            message = (str(error.get("message", "unknown error"))
                       if isinstance(error, dict) else str(error))
            code = error.get("code") if isinstance(error, dict) else None
            rpc_error = RpcError(code if isinstance(code, int) else None, message, data)
            self._record(method, params, stopwatch, error=str(rpc_error))
            raise rpc_error
        if "result" not in response:
            message = f"{method}: response has neither result nor error"
            self._record(method, params, stopwatch, error=message)
            raise ProtocolError(message)
        result = response["result"]
        shape_issues = self.schema.check_result(method, result)
        if shape_issues:
            message = "; ".join(shape_issues)
            self._record(method, params, stopwatch, error=message)
            raise ProtocolError(message)
        self._record(method, params, stopwatch, result=result)
        return result

    def _record(self, method: str, params: dict, stopwatch: Stopwatch, *,
                result: Any = None, error: str | None = None) -> None:
        entry = {
            "method": method,
            "duration_ms": round(stopwatch.elapsed_ms(), 1),
            "ok": error is None,
            "mutating": is_mutating(method),
        }
        if error:
            entry["error"] = error
        if result is not None and method in ("device_info", "logs", "page_source",
                                             "find_element", "reset"):
            entry["result_keys"] = sorted(result) if isinstance(result, dict) else type(result).__name__
        self.calls.append(entry)
        self.evidence.rpc(method, ok=error is None,
                          duration_ms=entry["duration_ms"], params=params, error=error)
        self.evidence.event("rpc_result", method=method, ok=error is None,
                            duration_ms=entry["duration_ms"], error=error)

    # ---------------------------------------------------------- timeout safety
    def resolve_timeout(self, method: str | None = None, *,
                        polls: int = 5) -> TimeoutResolution:
        """Resolve an ambiguous call from the device log; never resend the action."""
        if self.pending is None:
            return TimeoutResolution("not_pending", method or "", [], 0)
        target = method or self.pending.method
        if target != self.pending.method:
            raise DeviceError(
                f"pending timeout is for {self.pending.method!r}, not {target!r}")
        seen: list[str] = []
        for poll in range(1, polls + 1):
            try:
                result = self.invoke("logs", {"text": target, "max_elements": 300},
                                     timeout=self.log_timeout, mutating=False)
            except AmbiguousOutcome as error:
                return TimeoutResolution(
                    "unknown", target, seen, poll,
                    f"logs probe also timed out: {error}")
            lines = list(result.get("lines") or [])
            seen.extend(line for line in lines if line not in seen)
            completed = any(COMPLETED_MARK in line and target in line for line in lines)
            timed_out = any("TIMEOUT" in line.upper() and target in line for line in lines)
            if completed:
                self.pending = None
                return TimeoutResolution(
                    "completed", target, seen, poll,
                    "device log shows the timed-out call completed; it must not be resent")
            if timed_out:
                return TimeoutResolution(
                    "timed_out", target, seen, poll,
                    "device log shows the call timed out; the UI queue may be stuck. "
                    "Do not resend; ask the Lead/device owner to recover")
            if poll < polls:
                self._sleep(0.5)
        return TimeoutResolution(
            "unknown", target, seen, polls,
            "device log neither confirms nor denies completion; keep the lane blocked")

    def require_ready_for_actions(self) -> None:
        if self.pending is not None:
            raise PendingAmbiguity(
                f"{self.pending.method!r} timed out; check logs before acting")

    # ------------------------------------------------------------- operations
    def device_info(self) -> dict:
        result = self.invoke("device_info", {}, mutating=False)
        issues = self.schema.protocol_issues(result)
        if issues["errors"]:
            raise ProtocolError("; ".join(issues["errors"]))
        self.pending_warnings.extend(issues["warnings"])
        system = result.get("system")
        if isinstance(system, dict) and system.get("screen_locked") is True:
            raise DeviceError(
                "device screen is locked; a human must unlock it before any UI test")
        return result

    def is_locked(self) -> bool:
        result = self.invoke("is_locked", {}, mutating=False)
        return bool(result)

    def launch_app(self, bundle_id: str) -> dict:
        self.require_ready_for_actions()
        return self.invoke("launch_app", {"bundle_id": bundle_id})

    def terminate_app(self, bundle_id: str) -> dict:
        self.require_ready_for_actions()
        return self.invoke("terminate_app", {"bundle_id": bundle_id})

    def page_source(self, **params: Any) -> dict:
        return self.invoke("page_source", params, mutating=False)

    def find_element(self, element_id: str, **params: Any) -> dict:
        request = {"element_id": element_id}
        request.update(params)
        return self.invoke("find_element", request, mutating=False)

    def tap_ref(self, ref: str) -> dict:
        self.require_ready_for_actions()
        if not ref:
            raise DeviceError("refusing to tap an empty ref")
        return self.invoke("tap", {"ref": ref})

    def screenshot(self, name: str, *, scale: float = 1.0,
                   bundle_id: str | None = None,
                   evidence: EvidenceRun | None = None) -> Screenshot:
        run = evidence or self.evidence
        params: dict[str, Any] = {"format": "png", "scale": scale}
        if bundle_id:
            params["bundle_id"] = bundle_id
        stopwatch = Stopwatch()
        result = self.invoke("screenshot", params, mutating=False)
        capture_ms = stopwatch.elapsed_ms()
        try:
            blob = base64.b64decode(result["data"], validate=True)
        except (binascii.Error, KeyError, TypeError) as error:
            raise ProtocolError(f"screenshot: invalid base64 payload: {error}") from error
        declared = result.get("bytes")
        if isinstance(declared, int) and declared != len(blob):
            raise ProtocolError(
                f"screenshot: declared {declared} bytes, decoded {len(blob)}")
        if not blob.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ProtocolError("screenshot: response is not a PNG; request format=png")
        try:
            image = decode_png(blob)
        except PNGError as error:
            raise ProtocolError(
                f"screenshot: {error}; capture PNG at scale 1 or 2") from error
        meta = _screenshot_meta(result)
        target = run.path(name if name.endswith(".png") else name + ".png")
        target.write_bytes(blob)
        digest = hashlib.sha256(blob).hexdigest()
        run.event("screenshot", name=target.name, sha256=digest,
                  bytes=len(blob), pixel_width=image.width, pixel_height=image.height,
                  point_width=meta["point_width"], point_height=meta["point_height"],
                  scale=meta["scale"], capture_ms=round(capture_ms, 1))
        return Screenshot(
            path=target, sha256=digest, bytes_written=len(blob), format="png",
            pixel_width=image.width, pixel_height=image.height,
            point_width=meta["point_width"], point_height=meta["point_height"],
            scale=meta["scale"], image=image, capture_ms=capture_ms)

    def device_summary(self, info: dict | None = None) -> dict:
        return _safe_summary(info or {})
