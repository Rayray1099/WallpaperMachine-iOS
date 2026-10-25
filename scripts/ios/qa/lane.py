#!/usr/bin/env python3
"""Explicit device-lane lease: physical iCTRL access is serialized by the Lead.

The harness is safe by default: offline checks never touch the device, and a live
run requires **two** independent keys:

1. the `--device` flag, and
2. a non-expired lease file naming the QA Agent as holder and the Lead as grantor.

Only the Lead writes the lease (``lane.py grant --by Lead``); the QA Agent and its
scripts never grant themselves access. The lease lives under the Git-ignored
``artifacts/qa/`` tree so it cannot be committed.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import secrets

try:
    from . import qa_paths
except ImportError:  # pragma: no cover
    import qa_paths  # type: ignore[no-redef]

LEASE_VERSION = 1
HOLDER = "QA Agent"
GRANTOR = "Lead"


class LeaseError(RuntimeError):
    """A lease is missing, malformed, expired, or granted to someone else."""


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _format(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _parse(value: object) -> datetime:
    if not isinstance(value, str) or not value:
        raise LeaseError("lease timestamps must be non-empty ISO-8601 strings")
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as error:
        raise LeaseError(f"invalid lease timestamp {value!r}") from error
    if parsed.tzinfo is None:
        raise LeaseError(f"lease timestamp {value!r} has no timezone")
    return parsed.astimezone(timezone.utc)


@dataclass(frozen=True)
class Lease:
    path: Path
    holder: str
    granted_by: str
    granted_at: datetime
    expires_at: datetime
    note: str

    def active(self, now: datetime | None = None) -> bool:
        now = now or _utc_now()
        return self.granted_at <= now < self.expires_at


def load_lease(path: str | os.PathLike[str] | None = None,
               *, holder: str = HOLDER, granted_by: str = GRANTOR,
               now: datetime | None = None) -> Lease:
    """Read and validate the Lead's hand-off lease without calling the device."""
    lease_path = Path(path) if path else qa_paths.DEVICE_LANE
    try:
        raw = json.loads(lease_path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise LeaseError(
            f"no device lane lease at {lease_path}; the Lead must grant one with "
            "`python scripts/ios/qa/lane.py grant --by Lead --minutes 30`") from error
    except (OSError, json.JSONDecodeError) as error:
        raise LeaseError(f"cannot read device lane lease at {lease_path}: {error}") from error

    if not isinstance(raw, dict):
        raise LeaseError(f"device lane lease at {lease_path} must be a JSON object")
    if raw.get("version") != LEASE_VERSION:
        raise LeaseError(f"unsupported device lane lease version {raw.get('version')!r}")
    if raw.get("holder") != holder:
        raise LeaseError(
            f"device lane is held by {raw.get('holder')!r}, not {holder!r}; "
            "live access is serialized by the Lead")
    if raw.get("granted_by") != granted_by:
        raise LeaseError(
            f"device lane lease was granted by {raw.get('granted_by')!r}, not {granted_by!r}")

    lease = Lease(
        path=lease_path,
        holder=str(raw["holder"]),
        granted_by=str(raw["granted_by"]),
        granted_at=_parse(raw.get("granted_at")),
        expires_at=_parse(raw.get("expires_at")),
        note=str(raw.get("note", "")),
    )
    reference = now or _utc_now()
    if not lease.active(reference):
        raise LeaseError(
            f"device lane lease expired at {_format(lease.expires_at)}; ask the Lead to renew it")
    return lease


def grant(path: str | os.PathLike[str] | None = None, *, by: str,
          minutes: int, note: str = "") -> Lease:
    """Write a lease. This is the Lead's action; QA never runs it for itself."""
    if not by.strip():
        raise LeaseError("grantor name is required (use --by Lead)")
    if minutes < 1 or minutes > 240:
        raise LeaseError("lease minutes must be between 1 and 240")
    lease_path = Path(path) if path else qa_paths.DEVICE_LANE
    now = _utc_now()
    expires = now + timedelta(minutes=minutes)
    payload = {
        "version": LEASE_VERSION,
        "holder": HOLDER,
        "granted_by": by.strip(),
        "granted_at": _format(now),
        "expires_at": _format(expires),
        "note": note,
        "nonce": secrets.token_hex(8),
    }
    lease_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = lease_path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, lease_path)
    try:
        os.chmod(lease_path, 0o600)
    except OSError:
        pass
    return Lease(
        path=lease_path,
        holder=HOLDER,
        granted_by=by.strip(),
        granted_at=now,
        expires_at=expires,
        note=note,
    )


def release(path: str | os.PathLike[str] | None = None) -> bool:
    """Delete the lease; returns whether one existed."""
    lease_path = Path(path) if path else qa_paths.DEVICE_LANE
    try:
        lease_path.unlink()
        return True
    except FileNotFoundError:
        return False


def status(path: str | os.PathLike[str] | None = None) -> dict:
    """Report lease state without raising, for the status command."""
    lease_path = Path(path) if path else qa_paths.DEVICE_LANE
    try:
        lease = load_lease(lease_path)
    except LeaseError as error:
        return {"path": str(lease_path), "active": False, "error": str(error)}
    return {
        "path": str(lease_path),
        "active": lease.active(),
        "holder": lease.holder,
        "granted_by": lease.granted_by,
        "granted_at": _format(lease.granted_at),
        "expires_at": _format(lease.expires_at),
        "note": lease.note,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lane", default=None, help="lease file (default artifacts/qa/device-lane.json)")
    subparsers = parser.add_subparsers(dest="command", required=True)

    grant_parser = subparsers.add_parser("grant", help="write a Lead hand-off lease")
    grant_parser.add_argument("--by", required=True, help="grantor name; the harness requires 'Lead'")
    grant_parser.add_argument("--minutes", type=int, default=30, help="lease lifetime (1-240 minutes)")
    grant_parser.add_argument("--note", default="", help="why the lane was handed over")

    subparsers.add_parser("status", help="print lease state")
    subparsers.add_parser("check", help="exit non-zero unless a valid QA lease exists")
    subparsers.add_parser("release", help="delete the lease")

    args = parser.parse_args(argv)
    if args.command == "grant":
        try:
            lease = grant(args.lane, by=args.by, minutes=args.minutes, note=args.note)
        except LeaseError as error:
            print(f"ERROR: {error}")
            return 1
        print(f"device lane granted to {lease.holder} by {lease.granted_by} "
              f"until {_format(lease.expires_at)} ({lease.path})")
        return 0
    if args.command == "status":
        print(json.dumps(status(args.lane), indent=2))
        return 0
    if args.command == "check":
        try:
            lease = load_lease(args.lane)
        except LeaseError as error:
            print(f"ERROR: {error}")
            return 1
        print(f"device lane active for {lease.holder} until {_format(lease.expires_at)}")
        return 0
    if args.command == "release":
        removed = release(args.lane)
        print("device lane lease released" if removed else "no device lane lease to release")
        return 0
    raise AssertionError(args.command)


if __name__ == "__main__":
    raise SystemExit(main())
