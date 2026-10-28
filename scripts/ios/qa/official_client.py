#!/usr/bin/env python3
"""Load the downloaded official iCTRL client as a module, never reimplement its crypto.

The official `ictrl_rpc.py` is downloaded from the device
(`GET /skill/clients/python`). The QA harness imports it and calls its protocol
function directly so every device request stays inside the journaled session
and the harness can enforce its no-retry policy. The standalone CLI remains a
useful operator tool, but it is intentionally not used by QA.

The client owns pairing and the encrypted envelope (X25519 for LAN pairing,
HMAC-SHA256 envelopes for requests). This module only locates it and checks that
the expected protocol functions are present; it does not implement or alter any
cryptography. The token file is read by the official client, never by us, and is
never printed or copied.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import importlib.util
import os
from pathlib import Path
import sys
from types import ModuleType
from typing import Any

try:
    from . import qa_paths
except ImportError:  # pragma: no cover - direct script/test import
    import qa_paths  # type: ignore[no-redef]


class OfficialClientError(RuntimeError):
    """The official client is missing, unreadable, or does not expose its protocol API."""


@dataclass(frozen=True)
class OfficialClient:
    """A loaded official client module plus the facts needed to cite it."""

    path: Path
    sha256: str
    module: ModuleType

    def call(self, host: str, method: str, params: dict | None = None,
             timeout: float = 60.0) -> dict:
        """One official encrypted JSON-RPC call.

        `call` raises `SystemExit` for missing credentials or non-200 HTTP
        responses and lets transport timeouts propagate; `device_session`
        translates both. This wrapper deliberately adds no retries.
        """
        return self.module.call(host, method, params or {}, timeout=timeout)

    @property
    def token_store(self) -> Path:
        """Path of the official client's cached token store (contents never read here)."""
        return Path(str(self.module.STORE))

    def token_store_exists(self) -> bool:
        """Whether the official client has cached credentials, without reading them."""
        return self.token_store.is_file()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_client_path(explicit: str | os.PathLike[str] | None = None) -> Path:
    """Locate the downloaded official client without touching the device."""
    if explicit:
        candidate = Path(explicit).expanduser().resolve()
        if not candidate.is_file():
            raise OfficialClientError(f"iCTRL client not found at {candidate}")
        return candidate

    environment = os.environ.get(qa_paths.CLIENT_ENV, "").strip()
    if environment:
        candidate = Path(environment).expanduser().resolve()
        if not candidate.is_file():
            raise OfficialClientError(
                f"{qa_paths.CLIENT_ENV} points at {candidate}, which is not a file")
        return candidate

    for candidate in qa_paths.OFFICIAL_CLIENT_CANDIDATES:
        if candidate.is_file():
            return candidate.resolve()
    searched = ", ".join(str(path) for path in qa_paths.OFFICIAL_CLIENT_CANDIDATES)
    raise OfficialClientError(
        "official iCTRL client not found; download it with "
        "`curl -o ictrl_rpc.py http://<host>:8200/skill/clients/python` into "
        f"<checkout parent>/.local/ictrl/ (searched: {searched})")


def load_official_client(explicit: str | os.PathLike[str] | None = None) -> OfficialClient:
    """Import the official client from its path and verify its protocol surface."""
    path = resolve_client_path(explicit)
    digest = _sha256(path)
    spec = importlib.util.spec_from_file_location("ictrl_rpc_official", path)
    if spec is None or spec.loader is None:
        raise OfficialClientError(f"cannot import iCTRL client at {path}")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as error:  # noqa: BLE001 - report the concrete import failure
        raise OfficialClientError(f"importing iCTRL client at {path} failed: {error}") from error

    required = ("call", "load_token", "save_token", "STORE", "LABEL_ENC_REQ",
                "LABEL_ENC_RESP", "LABEL_MAC", "_keystream_xor")
    missing = [name for name in required if not hasattr(module, name)]
    if missing:
        raise OfficialClientError(
            f"{path} is not the official iCTRL client (missing {', '.join(missing)})")

    doc = (getattr(module, "__doc__", "") or "").lower()
    if "ictrl" not in doc or "json-rpc" not in doc:
        raise OfficialClientError(f"{path} does not look like the official iCTRL client")

    return OfficialClient(path=path, sha256=digest, module=module)


def resolve_schema_path(explicit: str | os.PathLike[str] | None = None) -> Path:
    """Locate the schema JSON captured from `GET /schema`."""
    if explicit:
        candidate = Path(explicit).expanduser().resolve()
        if not candidate.is_file():
            raise OfficialClientError(f"iCTRL schema not found at {candidate}")
        return candidate

    environment = os.environ.get(qa_paths.SCHEMA_ENV, "").strip()
    if environment:
        candidate = Path(environment).expanduser().resolve()
        if not candidate.is_file():
            raise OfficialClientError(
                f"{qa_paths.SCHEMA_ENV} points at {candidate}, which is not a file")
        return candidate

    for candidate in qa_paths.SCHEMA_CANDIDATES:
        if candidate.is_file():
            return candidate.resolve()
    searched = ", ".join(str(path) for path in qa_paths.SCHEMA_CANDIDATES)
    raise OfficialClientError(
        f"iCTRL schema not found (searched: {searched}); capture it from GET /schema")


def client_offline_report(explicit: str | os.PathLike[str] | None = None) -> dict:
    """Facts about the client suitable for a report: path, hash, token-file presence."""
    client = load_official_client(explicit)
    return {
        "path": str(client.path),
        "sha256": client.sha256,
        "token_store_exists": client.token_store_exists(),
        "token_store_path": str(client.token_store),
        "python": sys.version.split()[0],
    }
