#!/usr/bin/env python3
"""Fixtures shared by the iOS QA Python tests: synthetic schema, client and images."""
from __future__ import annotations

import base64
import json
from pathlib import Path
import sys

QA_DIR = Path(__file__).resolve().parents[1]
if str(QA_DIR) not in sys.path:
    sys.path.insert(0, str(QA_DIR))

from png_image import PNGImage, encode_png  # noqa: E402
import schema_contract  # noqa: E402


def parameter(name: str, kind: str, required: bool = False) -> dict:
    return {"name": name, "type": kind, "required": required, "description": ""}


def method(name: str, params: list[dict] | None = None, returns: str = "") -> dict:
    return {"name": name, "description": "", "returns": returns, "params": params or []}


def default_methods() -> list[dict]:
    return [
        method("device_info"),
        method("logs", [parameter("text", "string"), parameter("max_elements", "number")],
               "{lines, count}"),
        method("page_source", [parameter("visible_only", "boolean"),
                               parameter("max_children", "number"),
                               parameter("bundle_id", "string")], "{source}"),
        method("find_element", [parameter("element_id", "string", True),
                                parameter("element_type", "string"),
                                parameter("match", "string"),
                                parameter("bundle_id", "string")], "{exists, ref}"),
        method("screenshot", [parameter("format", "string"),
                              parameter("scale", "number"),
                              parameter("bundle_id", "string")],
               "{data, format, pixel_width, pixel_height, point_width, point_height, scale}"),
        method("tap", [parameter("ref", "string"), parameter("x", "number"),
                       parameter("y", "number")], "{message}"),
        method("launch_app", [parameter("bundle_id", "string", True)], "{message}"),
        method("terminate_app", [parameter("bundle_id", "string", True)], "{message}"),
        method("is_locked", [], "boolean"),
        method("reset", [], "{reset}"),
        method("resolve_app", [parameter("text", "string", True)], "{count, apps}"),
        method("open_url", [parameter("url", "string", True)], "{message}"),
    ]


def write_schema(directory: Path, methods: list[dict] | None = None,
                 protocol_version: int = 1) -> Path:
    payload = {
        "protocol_version": protocol_version,
        "protocol": "JSON-RPC 2.0",
        "server_version": "test-1.0",
        "build": "test",
        "methods": methods if methods is not None else default_methods(),
    }
    path = Path(directory) / "schema.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def make_schema(directory: Path, methods: list[dict] | None = None) -> schema_contract.Schema:
    return schema_contract.load_schema(write_schema(directory, methods))


def device_info_result(**overrides) -> dict:
    result = {
        "device_name": "QA iPad",
        "model": "iPad",
        "point_width": 834,
        "point_height": 1194,
        "pixel_width": 1668,
        "pixel_height": 2388,
        "scale": 2,
        "server_version": "1.96.1",
        "protocol_version": 1,
        "capabilities": ["envelope_v1", "screenshot_jpeg"],
        "system": {"screen_locked": False, "foreground_app": "com.rayray1099.wallpapermachine.ios"},
    }
    result.update(overrides)
    return result


def solid_image(width: int = 20, height: int = 20, colour: tuple[int, int, int] = (20, 30, 40),
                channels: int = 3) -> PNGImage:
    pixels = bytearray()
    for _ in range(width * height):
        pixels.extend(colour[:channels] if channels < 4 else (*colour, 255))
    return PNGImage(width=width, height=height, channels=channel_count(channels), data=bytes(pixels))


def channel_count(channels: int) -> int:
    return channels


def image_with_rect(width: int, height: int, rect: tuple[int, int, int, int],
                    colour: tuple[int, int, int] = (250, 250, 250),
                    background: tuple[int, int, int] = (10, 10, 10)) -> PNGImage:
    data = bytearray()
    x0, y0, rect_width, rect_height = rect
    for y in range(height):
        for x in range(width):
            inside = x0 <= x < x0 + rect_width and y0 <= y < y0 + rect_height
            data.extend(colour if inside else background)
    return PNGImage(width=width, height=height, channels=3, data=bytes(data))


def screenshot_result(image: PNGImage, *, point_scale: float = 2.0) -> dict:
    blob = encode_png(image)
    return {
        "data": base64.b64encode(blob).decode("ascii"),
        "format": "png",
        "bytes": len(blob),
        "pixel_width": image.width,
        "pixel_height": image.height,
        "point_width": int(image.width / point_scale),
        "point_height": int(image.height / point_scale),
        "scale": point_scale,
    }


class ScriptedClient:
    """A fake official client: records calls and returns scripted outcomes in order."""

    def __init__(self, script: list):
        self.script = list(script)
        self.calls: list[tuple[str, dict, float]] = []

    def call(self, host: str, method: str, params: dict | None = None,
             timeout: float = 60.0) -> dict:
        self.calls.append((method, dict(params or {}), timeout))
        if not self.script:
            raise AssertionError(f"unexpected call {method}: script is exhausted")
        outcome = self.script.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        if callable(outcome):
            return outcome(host, method, params or {}, timeout)
        return outcome


def envelope(result) -> dict:
    return {"jsonrpc": "2.0", "id": 1, "result": result}


def rpc_error(code: int = -32602, message: str = "invalid params") -> dict:
    return {"jsonrpc": "2.0", "id": 1, "error": {"code": code, "message": message}}
