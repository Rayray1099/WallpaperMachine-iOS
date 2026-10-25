#!/usr/bin/env python3
"""Durable, secret-free evidence for an iOS QA run.

Everything a run produces — JSON-RPC timing log, screenshots, frame metrics and
the final report — goes under one Git-ignored ``artifacts/qa/runs/<timestamp>/``
directory. Tokens, keys and the token file's contents are never read or written;
RPC parameters are sanitized before they reach the log (typed text and image
payloads are reduced to lengths).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
import json
from pathlib import Path
import time
from typing import Any

try:
    from . import qa_paths
except ImportError:  # pragma: no cover
    import qa_paths  # type: ignore[no-redef]

SENSITIVE_KEYS = ("token", "tok", "key", "secret", "password", "credential", "nonce", "tag", "ct")
MAX_STRING = 4096


def utc_stamp(moment: datetime | None = None) -> str:
    moment = moment or datetime.now(timezone.utc)
    return moment.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def sanitize(value: Any, *, key: str = "") -> Any:
    """Copy a JSON-like value with secrets removed and long payloads summarized."""
    lowered = key.lower()
    if any(word in lowered for word in SENSITIVE_KEYS):
        return "<redacted>"
    if isinstance(value, dict):
        return {str(item_key): sanitize(item_value, key=str(item_key))
                for item_key, item_value in value.items()}
    if isinstance(value, (list, tuple)):
        return [sanitize(item) for item in value]
    if isinstance(value, str):
        if key in ("data", "ct") and len(value) > 64:
            return f"<{len(value)} characters>"
        if len(value) > MAX_STRING:
            return value[:MAX_STRING] + f"… <{len(value) - MAX_STRING} more characters>"
        return value
    return value


@dataclass
class EvidenceRun:
    """One run's evidence directory and report."""

    kind: str
    directory: Path
    started_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    events: list[dict] = field(default_factory=list)
    report: dict = field(default_factory=dict)

    @classmethod
    def create(cls, kind: str, directory: str | Path | None = None) -> "EvidenceRun":
        if directory:
            path = Path(directory)
        else:
            path = qa_paths.QA_ARTIFACTS / "runs" / f"{utc_stamp()}-{kind}"
        path.mkdir(parents=True, exist_ok=True)
        return cls(kind=kind, directory=path)

    # ------------------------------------------------------------- primitives
    def path(self, name: str) -> Path:
        target = self.directory / name
        target.parent.mkdir(parents=True, exist_ok=True)
        return target

    def write_json(self, name: str, payload: Any) -> Path:
        target = self.path(name)
        target.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
                          encoding="utf-8")
        return target

    def write_text(self, name: str, text: str) -> Path:
        target = self.path(name)
        target.write_text(text, encoding="utf-8")
        return target

    def write_bytes(self, name: str, payload: bytes) -> Path:
        target = self.path(name)
        target.write_bytes(payload)
        return target

    # ----------------------------------------------------------------- events
    def event(self, kind: str, **fields: Any) -> None:
        entry = {"at": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                 "kind": kind}
        entry.update(sanitize(fields))
        self.events.append(entry)

    def rpc(self, method: str, *, ok: bool, duration_ms: float,
            params: dict | None = None, error: str | None = None) -> None:
        entry = {
            "at": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "method": method,
            "ok": ok,
            "duration_ms": round(duration_ms, 1),
        }
        if params:
            entry["params"] = sanitize(params)
        if error:
            entry["error"] = sanitize(error)
        self.events.append({"kind": "rpc", **entry})

    # ----------------------------------------------------------------- report
    def set_report(self, **fields: Any) -> None:
        self.report.update(fields)

    def finish(self, ok: bool, *, errors: list[str] | None = None,
               notes: list[str] | None = None) -> dict:
        finished = datetime.now(timezone.utc)
        report = dict(self.report)
        report.update({
            "kind": self.kind,
            "ok": ok,
            "started_at": self.started_at.isoformat(timespec="seconds"),
            "finished_at": finished.isoformat(timespec="seconds"),
            "duration_s": round((finished - self.started_at).total_seconds(), 2),
            "evidence_directory": str(self.directory),
            "errors": errors or [],
            "notes": notes or [],
            "not_measured": [
                "application FPS",
                "application CPU time",
                "application memory footprint",
                "thermals attributable to the application",
            ],
            "measurement_boundary": (
                "iCTRL capture latency and sampled content change are not application "
                "frame rate, CPU or memory; iCTRL runner metrics are not app metrics"),
        })
        self.report = report
        self.write_json("report.json", report)
        # JSONL is more useful for long logs; one event per line.
        lines = [json.dumps(event, ensure_ascii=False) for event in self.events]
        self.path("rpc.jsonl").write_text("\n".join(lines) + ("\n" if lines else ""),
                                          encoding="utf-8")
        self.write_json("events.json", self.events)
        return report


@dataclass
class Stopwatch:
    """Wall-clock timing for one operation (never presented as frame rate)."""

    started: float = field(default_factory=time.monotonic)

    def elapsed_ms(self) -> float:
        return (time.monotonic() - self.started) * 1000.0
