#!/usr/bin/env python3
"""Validate iCTRL requests and results against the schema captured from the device.

`GET /schema` describes every method, its parameters, types and required flags,
and returns a prose `returns` string. The prose is not machine-readable, so this
module owns a small, explicit result-shape table for the methods the QA harness
uses. A JSON-RPC *error* (HTTP 200 with an `error` member) is rejected by
`device_session`, not here; this module only checks the success envelope's
`result` object.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
from typing import Any

try:
    from . import official_client
except ImportError:  # pragma: no cover
    import official_client  # type: ignore[no-redef]


class SchemaError(RuntimeError):
    """The schema file is missing, malformed, or from an incompatible protocol."""


# Required members of a successful result for every method the harness calls.
RESULT_SHAPES: dict[str, tuple[str, ...]] = {
    "device_info": ("point_width", "point_height", "pixel_width",
                    "pixel_height", "scale"),
    "screenshot": ("data", "format", "pixel_width", "pixel_height",
                   "point_width", "point_height", "scale"),
    "logs": ("lines", "count"),
    "page_source": ("source",),
    "find_element": ("exists",),
    "launch_app": ("message",),
    "terminate_app": ("message",),
    "open_url": ("message",),
    "tap": ("message",),
    "reset": ("reset",),
}

# Capability tags the harness relies on. Missing tags are reported as warnings by
# the live runner, not fatal: the server may add or rename advisory tags.
REQUIRED_CAPABILITIES = ("envelope_v1",)

TYPE_CHECKS = {
    "string": lambda value: isinstance(value, str),
    "number": lambda value: isinstance(value, (int, float)) and not isinstance(value, bool),
    "boolean": lambda value: isinstance(value, bool),
    "object": lambda value: isinstance(value, dict),
    "array": lambda value: isinstance(value, list),
}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


@dataclass(frozen=True)
class Method:
    name: str
    description: str
    params: dict[str, dict]
    returns: str

    def required_params(self) -> tuple[str, ...]:
        return tuple(name for name, spec in self.params.items() if spec.get("required"))

    def forbidden_params(self) -> tuple[str, ...]:
        return ()


@dataclass(frozen=True)
class Schema:
    path: Path
    sha256: str
    protocol_version: int
    server_version: str
    build: str
    methods: dict[str, Method]

    def method(self, name: str) -> Method:
        try:
            return self.methods[name]
        except KeyError as error:
            raise SchemaError(f"method {name!r} is not in the captured schema") from error

    def check_request(self, name: str, params: dict | None) -> list[str]:
        """Return every schema violation for one request; empty means valid."""
        issues: list[str] = []
        try:
            method = self.method(name)
        except SchemaError as error:
            return [str(error)]
        if params is None:
            params = {}
        if not isinstance(params, dict):
            return [f"{name}: params must be an object, got {type(params).__name__}"]
        for key in params:
            if key not in method.params:
                issues.append(f"{name}: unknown parameter {key!r}")
        for key in method.required_params():
            if key not in params:
                issues.append(f"{name}: missing required parameter {key!r}")
        for key, value in params.items():
            spec = method.params.get(key)
            if not spec:
                continue
            expected = spec.get("type")
            check = TYPE_CHECKS.get(str(expected)) if expected else None
            if check is not None and not check(value):
                issues.append(
                    f"{name}: parameter {key!r} must be {expected}, got {type(value).__name__}")
        return issues

    def check_result(self, name: str, result: Any) -> list[str]:
        """Return every shape violation for a success result; empty means valid."""
        issues: list[str] = []
        shape = RESULT_SHAPES.get(name)
        if shape is None:
            return issues
        if not isinstance(result, dict):
            return [f"{name}: result must be an object, got {type(result).__name__}"]
        for key in shape:
            if key not in result:
                issues.append(f"{name}: result is missing {key!r}")
        if issues:
            return issues

        if name in ("device_info", "screenshot"):
            for key in ("point_width", "point_height", "pixel_width",
                        "pixel_height", "scale"):
                value = result.get(key)
                if not isinstance(value, (int, float)) or isinstance(value, bool):
                    issues.append(f"{name}: {key} must be a number")
                elif value <= 0:
                    issues.append(f"{name}: {key} must be positive")
        if name == "screenshot":
            if result.get("format") not in ("png", "jpeg"):
                issues.append("screenshot: format must be 'png' or 'jpeg'")
            if not isinstance(result.get("data"), str) or not result.get("data"):
                issues.append("screenshot: data must be a non-empty base64 string")
        if name == "logs":
            lines = result.get("lines")
            if not isinstance(lines, list) or not all(isinstance(line, str) for line in lines):
                issues.append("logs: lines must be an array of strings")
            count = result.get("count")
            if not isinstance(count, int) or isinstance(count, bool) or count < 0:
                issues.append("logs: count must be a non-negative integer")
            elif isinstance(lines, list) and count < len(lines):
                issues.append(
                    f"logs: count {count} is smaller than {len(lines)} returned lines")
        if name == "page_source" and not isinstance(result.get("source"), str):
            issues.append("page_source: source must be a string")
        if name == "find_element":
            exists = result.get("exists")
            if not isinstance(exists, bool):
                issues.append("find_element: exists must be a boolean")
            elif exists and not result.get("ref"):
                issues.append("find_element: a found element must carry a non-empty ref")
        if name in ("launch_app", "terminate_app", "open_url", "tap"):
            if not isinstance(result.get("message"), str):
                issues.append(f"{name}: message must be a string")
        if name == "reset" and not isinstance(result.get("reset"), bool):
            issues.append("reset: reset must be a boolean")
        return issues

    def protocol_issues(self, device_info: dict) -> dict[str, list[str]]:
        """Compare a live `device_info` result with the captured schema."""
        errors: list[str] = []
        warnings: list[str] = []
        live_protocol = device_info.get("protocol_version")
        if live_protocol != self.protocol_version:
            errors.append(
                f"protocol mismatch: device {live_protocol!r}, schema {self.protocol_version}")
        capabilities = device_info.get("capabilities")
        if not isinstance(capabilities, list):
            warnings.append("device_info did not report a capabilities array")
        else:
            missing = [tag for tag in REQUIRED_CAPABILITIES if tag not in capabilities]
            if missing:
                warnings.append("missing capabilities: " + ", ".join(missing))
        return {"errors": errors, "warnings": warnings}


def load_schema(explicit: str | Path | None = None) -> Schema:
    """Load and structurally check the captured schema JSON."""
    try:
        path = official_client.resolve_schema_path(explicit)
    except official_client.OfficialClientError as error:
        raise SchemaError(str(error)) from error
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SchemaError(f"cannot read schema at {path}: {error}") from error
    if not isinstance(raw, dict):
        raise SchemaError(f"schema at {path} must be a JSON object")
    if raw.get("protocol") != "JSON-RPC 2.0":
        raise SchemaError(f"schema at {path} is not JSON-RPC 2.0")

    methods: dict[str, Method] = {}
    entries = raw.get("methods")
    if not isinstance(entries, list) or not entries:
        raise SchemaError(f"schema at {path} has no methods")
    for entry in entries:
        if not isinstance(entry, dict) or not entry.get("name"):
            raise SchemaError(f"schema at {path} has a malformed method entry")
        params = {}
        for parameter in entry.get("params") or []:
            if not isinstance(parameter, dict) or not parameter.get("name"):
                raise SchemaError(
                    f"schema method {entry['name']!r} has a malformed parameter")
            params[parameter["name"]] = parameter
        methods[entry["name"]] = Method(
            name=entry["name"],
            description=str(entry.get("description", "")),
            params=params,
            returns=str(entry.get("returns", "")),
        )

    try:
        protocol_version = int(raw["protocol_version"])
    except (KeyError, TypeError, ValueError) as error:
        raise SchemaError(f"schema at {path} has no usable protocol_version") from error

    return Schema(
        path=path,
        sha256=_sha256(path),
        protocol_version=protocol_version,
        server_version=str(raw.get("server_version", "unknown")),
        build=str(raw.get("build", "unknown")),
        methods=methods,
    )


def schema_report(schema: Schema) -> dict:
    return {
        "path": str(schema.path),
        "sha256": schema.sha256,
        "protocol_version": schema.protocol_version,
        "server_version": schema.server_version,
        "build": schema.build,
        "method_count": len(schema.methods),
    }
