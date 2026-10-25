#!/usr/bin/env python3
"""Run the WallpaperMachine iOS QA checks: offline regression and a gated live pass.

Offline (default): loads the downloaded official iCTRL client without using its
broken-on-Windows CLI, validates the captured schema, runs the QA Python tests,
checks the UI accessibility-ID contract statically, syntax-parses the iOS Swift
tests when a Swift compiler is available, and exercises Build Agent's IPA
validator with synthetic fixtures when it exists. It never touches the device.

Live (``--device --lane <lease>``): requires the Lead's explicit device-lane
lease; captures the app window multiple times, proves advancing animation from
lossless PNG content differences (not timestamps and not an invented FPS), audits
the full ``wm.*`` accessibility contract, and records secret-free evidence under
Git-ignored ``artifacts/qa/``. It never retries a timed-out action: it resolves
the ambiguity from the device's ``logs`` lane first.
"""
from __future__ import annotations

import argparse
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import unittest

QA_DIR = Path(__file__).resolve().parent
if str(QA_DIR) not in sys.path:
    sys.path.insert(0, str(QA_DIR))

import qa_paths  # noqa: E402
from evidence import EvidenceRun, utc_stamp  # noqa: E402
from frame_evidence import evaluate_animation  # noqa: E402
from lib.glyphs import markers  # noqa: E402
import lane  # noqa: E402
import official_client  # noqa: E402
import package_contract  # noqa: E402
from device_session import (  # noqa: E402
    AmbiguousOutcome, DeviceError, DeviceSession, DeviceUnreachable, PendingAmbiguity,
)
from png_image import PNGError  # noqa: E402
import schema_contract  # noqa: E402
import ui_contract  # noqa: E402

MARK = markers()
UNIT_TEST_DIR = QA_DIR / "tests"


def _print(prefix: str, message: str) -> None:
    print(f"{prefix} {message}")


def _section(title: str) -> None:
    print(f"\n{title}")


def _host_parts(host: str) -> tuple[str, int]:
    if host.startswith("["):
        name, _, tail = host.partition("]")
        port = int(tail.lstrip(":") or 8200)
        return name.lstrip("["), port
    name, _, port_text = host.partition(":")
    return name or "127.0.0.1", int(port_text or 8200)


def reachability(host: str, timeout: float = 1.5) -> dict:
    """TCP reachability only: no RPC, no pairing, no device method."""
    name, port = _host_parts(host)
    started = time.monotonic()
    try:
        with socket.create_connection((name, port), timeout=timeout):
            pass
        return {"reachable": True, "host": host,
                "duration_ms": round((time.monotonic() - started) * 1000.0, 1)}
    except OSError as error:
        return {"reachable": False, "host": host, "error": str(error),
                "duration_ms": round((time.monotonic() - started) * 1000.0, 1)}


# --------------------------------------------------------------------- offline
def run_unit_tests(verbose: bool) -> unittest.TestResult:
    if not UNIT_TEST_DIR.is_dir():
        raise SystemExit(f"QA unit tests are missing at {UNIT_TEST_DIR}")
    loader = unittest.TestLoader()
    suite = loader.discover(str(UNIT_TEST_DIR), pattern="test_*.py",
                            top_level_dir=str(UNIT_TEST_DIR))
    runner = unittest.TextTestRunner(stream=sys.stdout, verbosity=2 if verbose else 1)
    return runner.run(suite)


def swift_parse_check(directory: Path) -> dict:
    compiler = subprocess.run(["swiftc", "--version"], capture_output=True, text=True)
    if compiler.returncode != 0:
        return {"available": False, "reason": "swiftc is not installed",
                "files": [], "failures": []}
    files = sorted(directory.rglob("*.swift"))
    if not files:
        return {"available": True, "reason": "no iOS test sources yet",
                "files": [], "failures": []}
    failures = []
    for path in files:
        parsed = subprocess.run(["swiftc", "-parse", str(path)],
                                capture_output=True, text=True)
        if parsed.returncode != 0:
            failures.append({"file": str(path.relative_to(qa_paths.ROOT)),
                             "output": (parsed.stdout + parsed.stderr).strip()})
    return {"available": True, "reason": "", "files": [str(path) for path in files],
            "failures": failures,
            "version": compiler.stdout.splitlines()[0] if compiler.stdout else ""}


def validator_check(fixtures_root: Path, explicit: str | None) -> dict:
    validator = package_contract.discover_validator(explicit)
    if not validator:
        return {"available": False, "reason": "Build Agent's IPA validator has not landed",
                "cases": []}
    if validator.suffix != ".py":
        return {"available": False,
                "reason": f"{validator.name} is not a Python validator", "cases": []}
    if validator.name == "validate.py":
        # Build Agent's validator also needs a real built app, renderer archive,
        # manifest and checksums. QA exercises its structural checks directly in
        # tests/test_package_contract.py; a synthetic CLI invocation would only
        # prove that an incomplete build fails.
        return {"available": True, "path": str(validator),
                "mode": "QA Python tests exercise check_ipa/check_bundle/check_executable",
                "cases": [], "failures": []}
    directory = fixtures_root / "ipa-fixtures"
    cases = package_contract.positive_and_invalid_cases(directory)
    results = []
    failures = []
    for name, (ipa, should_pass) in cases.items():
        try:
            result = package_contract.run_validator(validator, ipa)
        except (OSError, subprocess.TimeoutExpired) as error:
            failures.append({"case": name, "error": str(error)})
            continue
        passed = (result.returncode == 0) == should_pass
        results.append({"case": name, "should_pass": should_pass,
                        "returncode": result.returncode, "ok": passed,
                        "output": result.output[-1200:]})
        if not passed:
            failures.append({"case": name, "expected_pass": should_pass,
                             "returncode": result.returncode,
                             "output": result.output[-1200:]})
    return {"available": True, "path": str(validator), "cases": results,
            "failures": failures}


def offline(args: argparse.Namespace) -> int:
    run = EvidenceRun.create("offline", args.evidence_dir)
    failures: list[str] = []
    report: dict = {"kind": "offline", "evidence_directory": str(run.directory)}

    _section("Official iCTRL client")
    try:
        client = official_client.load_official_client(args.client)
    except official_client.OfficialClientError as error:
        _print(MARK.missing, str(error))
        failures.append(str(error))
        client = None
    else:
        _print(MARK.ok, f"{client.path} (sha256 {client.sha256[:12]}…)")
        _print(MARK.ok if client.token_store_exists() else MARK.warn,
               f"cached credential file {'present' if client.token_store_exists() else 'absent'}"
               f" at {client.token_store} (never read by QA)")
        report["client"] = {
            "path": str(client.path), "sha256": client.sha256,
            "token_store_present": client.token_store_exists(),
            "cli_used": False,
        }

    _section("iCTRL schema")
    try:
        schema = schema_contract.load_schema(args.schema)
    except (official_client.OfficialClientError, schema_contract.SchemaError) as error:
        _print(MARK.missing, str(error))
        failures.append(str(error))
        schema = None
    else:
        _print(MARK.ok,
               f"protocol {schema.protocol_version}, server {schema.server_version}, "
               f"{len(schema.methods)} methods, {schema.path}")
        report["schema"] = schema_contract.schema_report(schema)

    _section("Device reachability (TCP probe only)")
    probe = reachability(args.host)
    report["reachability"] = probe
    if probe["reachable"]:
        _print(MARK.ok, f"{args.host} accepts TCP connections; no RPC sent")
    else:
        _print(MARK.warn,
               f"{args.host} not reachable ({probe.get('error')}); live checks cannot run")

    _section("QA Python tests")
    result = run_unit_tests(args.verbose)
    report["unit_tests"] = {
        "run": result.testsRun,
        "failures": len(result.failures),
        "errors": len(result.errors),
        "skipped": len(result.skipped),
        "ok": result.wasSuccessful(),
    }
    if not result.wasSuccessful():
        failures.append("QA Python tests failed")
    _print(MARK.ok if result.wasSuccessful() else MARK.missing,
           f"{result.testsRun} tests, {len(result.failures)} failures, "
           f"{len(result.errors)} errors, {len(result.skipped)} skipped")

    _section("iOS accessibility-ID contract (static)")
    static = ui_contract.static_audit()
    report["static_ui"] = static.as_dict()
    if not qa_paths.IOS_SOURCES.is_dir():
        _print(MARK.warn, "iOS/Sources has not landed yet; static UI audit skipped")
    elif static.missing:
        _print(MARK.warn,
               f"not yet referenced in iOS/Sources: {', '.join(static.missing)}")
    else:
        _print(MARK.ok, f"all {len(ui_contract.CONTRACT_UI_IDS)} contract IDs referenced")

    _section("iOS Swift test syntax")
    parsed = swift_parse_check(qa_paths.IOS_TESTS)
    report["swift_parse"] = parsed
    if not parsed["available"]:
        _print(MARK.warn, f"skipped: {parsed['reason']}")
    elif parsed["failures"]:
        _print(MARK.missing, f"{len(parsed['failures'])} file(s) failed to parse")
        failures.append("iOS Swift tests failed to parse")
    else:
        _print(MARK.ok if parsed["files"] else MARK.warn,
               f"{len(parsed['files'])} file(s) parsed" if parsed["files"]
               else parsed["reason"])

    _section("Unsigned IPA validator fixtures")
    if args.skip_validator:
        _print(MARK.warn, "skipped by --skip-validator")
        report["validator"] = {"available": False, "reason": "skipped by request"}
    else:
        validator = validator_check(run.directory, args.validator)
        report["validator"] = validator
        if not validator["available"]:
            _print(MARK.warn, f"skipped: {validator['reason']}")
        elif validator["failures"]:
            _print(MARK.missing,
                   f"{len(validator['failures'])} of {len(validator['cases'])} "
                   "validator fixtures behaved unexpectedly")
            failures.append("IPA validator fixtures failed")
        else:
            _print(MARK.ok,
                   f"{len(validator['cases'])} synthetic IPA cases matched expectations")

    ok = not failures
    run.set_report(**report)
    run.finish(ok, errors=failures)
    _section("Summary")
    _print(MARK.ok if ok else MARK.missing,
           f"offline QA {'passed' if ok else 'failed'}; evidence in {run.directory}")
    if failures:
        for failure in failures:
            _print(MARK.missing, failure)
    if args.print_json:
        print(json.dumps(json.loads((run.directory / "report.json").read_text(encoding="utf-8")),
                         indent=2))
    return 0 if ok else 1


# ------------------------------------------------------------------------ live
def _await_screen(session: DeviceSession, predicate, attempts: int = 8) -> str:
    last = ""
    for _ in range(attempts):
        source = str(session.page_source(visible_only=True, max_children=50).get("source", ""))
        last = source
        if predicate(source):
            return source
        session._sleep(0.5)  # noqa: SLF001 - bounded settle poll, not an action
    return last


def _tap_identifier(session: DeviceSession, identifier: str) -> None:
    element = session.find_element(identifier)
    if not element.get("exists"):
        raise DeviceError(f"{identifier} was not found on the current screen")
    if not element.get("hittable", True):
        raise DeviceError(f"{identifier} is present but not hittable")
    ref = str(element.get("ref", ""))
    session.tap_ref(ref)
    session._sleep(0.4)  # noqa: SLF001 - bounded settle after the single tap


def live(args: argparse.Namespace) -> int:
    try:
        lease = lane.load_lease(args.lane)
    except lane.LeaseError as error:
        _print(MARK.missing, f"device lane not granted: {error}")
        _print(MARK.warn, "no device method was called; ask the Lead to hand the lane")
        return 2

    run = EvidenceRun.create("live-device", args.evidence_dir)
    failures: list[str] = []
    warnings: list[str] = []
    report: dict = {"kind": "live-device", "host": args.host,
                    "lane": {"holder": lease.holder, "granted_by": lease.granted_by,
                             "expires_at": lease.expires_at.isoformat()},
                    "evidence_directory": str(run.directory)}

    client = official_client.load_official_client(args.client)
    schema = schema_contract.load_schema(args.schema)
    report["client"] = {"path": str(client.path), "sha256": client.sha256}
    report["schema"] = schema_contract.schema_report(schema)
    _print(MARK.ok, f"client {client.path.name} (sha256 {client.sha256[:12]}…), "
                    f"schema protocol {schema.protocol_version}")

    session = DeviceSession(client, schema, args.host, run, timeout=args.timeout)
    try:
        _section("Device")
        info = session.device_info()
        report["device"] = session.device_summary(info)
        report["device_protocol"] = schema.protocol_issues(info)
        if report["device_protocol"]["warnings"]:
            warnings.extend(report["device_protocol"]["warnings"])
            for warning in report["device_protocol"]["warnings"]:
                _print(MARK.warn, warning)
        _print(MARK.ok, f"device_info OK; screen "
                        f"{info.get('pixel_width')}x{info.get('pixel_height')} px, "
                        f"{info.get('point_width')}x{info.get('point_height')} pt")

        _section("App launch and accessibility contract")
        session.launch_app(args.bundle_id)
        source = _await_screen(session, lambda text: "wm.library" in text)
        if "wm.library" not in source:
            source = str(session.page_source(visible_only=True, max_children=50).get("source", ""))
        audit = ui_contract.live_audit(session, bundle_id=args.bundle_id, deep=True)
        report["ui"] = audit.as_dict()
        if audit.missing:
            failures.append(f"missing accessibility IDs: {', '.join(audit.missing)}")
            _print(MARK.missing, f"missing: {', '.join(audit.missing)}")
        else:
            _print(MARK.ok, f"all {len(ui_contract.CONTRACT_UI_IDS)} contract IDs present")

        for identifier in args.tap_wm_id:
            _section(f"Tap {identifier}")
            session.require_ready_for_actions()
            _tap_identifier(session, identifier)
            _print(MARK.ok, f"tapped {identifier} once")

        _section("Screenshots and animation content")
        first = session.screenshot("screen-01.png", scale=args.scale,
                                   bundle_id=args.bundle_id)
        _print(MARK.ok, f"screenshot {first.path.name} {first.pixel_width}x"
                        f"{first.pixel_height}px ({first.capture_ms:.0f} ms)")
        frames = [first.image]
        for index in range(1, args.frames):
            time.sleep(args.interval)
            shot = session.screenshot(f"frame-{index:02d}.png", scale=args.scale,
                                      bundle_id=args.bundle_id)
            frames.append(shot.image)
        verdict = evaluate_animation(
            frames, min_changed_ratio=args.min_changed_ratio,
            min_coverage=args.min_coverage, min_transitions=args.min_transitions)
        run.write_json("frame-evidence.json", verdict.as_dict())
        report["animation"] = verdict.as_dict()
        if verdict.passed:
            _print(MARK.ok, f"content changes across {len(frames)} samples: "
                            f"{verdict.reason}")
        else:
            failures.append(f"animation not proven: {verdict.reason}")
            _print(MARK.missing, f"animation not proven: {verdict.reason}")

    except AmbiguousOutcome as error:
        resolution = session.resolve_timeout()
        report["timeout_resolution"] = {
            "status": resolution.status, "method": resolution.method,
            "note": resolution.note, "lines": resolution.lines[-20:],
        }
        failures.append(str(error))
        failures.append(f"timeout resolution: {resolution.status} — {resolution.note}")
        _print(MARK.missing, f"{error}")
        _print(MARK.warn, f"logs resolution: {resolution.status} — {resolution.note}")
    except PendingAmbiguity as error:
        failures.append(str(error))
        _print(MARK.missing, str(error))
    except (DeviceUnreachable, DeviceError, PNGError,
            official_client.OfficialClientError, schema_contract.SchemaError) as error:
        failures.append(str(error))
        _print(MARK.missing, str(error))
    finally:
        report["rpc_calls"] = len(session.calls)
        report["timeouts"] = [entry for entry in session.calls if "timeout" in entry.get("error", "")]

    ok = not failures
    run.set_report(**report)
    run.finish(ok, errors=failures, notes=warnings)
    _section("Summary")
    _print(MARK.ok if ok else MARK.missing,
           f"live QA {'passed' if ok else 'failed'}; evidence in {run.directory}")
    _print(MARK.warn, "not measured: application FPS, CPU, memory, thermals "
                      "(iCTRL runner and capture timing are not app metrics)")
    for failure in failures:
        _print(MARK.missing, failure)
    if args.print_json:
        print(json.dumps(json.loads((run.directory / "report.json").read_text(encoding="utf-8")),
                         indent=2))
    return 0 if ok else 1


# ------------------------------------------------------------------------ main
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", action="store_true",
                        help="run the live device suite (requires the Lead's lane lease)")
    parser.add_argument("--lane", default=str(qa_paths.DEVICE_LANE),
                        help="device lane lease file written by the Lead")
    parser.add_argument("--host", default=os.environ.get(qa_paths.HOST_ENV, qa_paths.DEFAULT_HOST),
                        help="iCTRL host:port (default 127.0.0.1:8200)")
    parser.add_argument("--client", default=None,
                        help="official ictrl_rpc.py path (default: <checkout parent>/.local/ictrl)")
    parser.add_argument("--schema", default=None,
                        help="schema.json path captured from GET /schema")
    parser.add_argument("--bundle-id", default=qa_paths.BUNDLE_ID)
    parser.add_argument("--evidence-dir", default=None,
                        help="evidence directory (default artifacts/qa/runs/<timestamp>-<kind>)")
    parser.add_argument("--json", dest="print_json", action="store_true",
                        help="print the final report JSON")
    parser.add_argument("--verbose", action="store_true", help="verbose unit-test output")
    parser.add_argument("--timeout", type=float, default=45.0,
                        help="per-call client timeout, at least 30 s")
    parser.add_argument("--skip-validator", action="store_true",
                        help="offline: do not run the Build Agent validator fixtures")
    parser.add_argument("--validator", default=None,
                        help="offline: explicit IPA validator path")
    parser.add_argument("--frames", type=int, default=6,
                        help="live: number of screenshots sampled for animation")
    parser.add_argument("--interval", type=float, default=0.35,
                        help="live: target seconds between screenshot starts")
    parser.add_argument("--scale", type=float, default=1.0,
                        help="live: screenshot pixels per point (1 is enough for diffing)")
    parser.add_argument("--tap-wm-id", action="append", default=[],
                        metavar="WM_ID",
                        help="live: tap this accessibility identifier once before sampling")
    parser.add_argument("--min-changed-ratio", type=float, default=0.01,
                        help="live: per-transition changed-pixel floor (default 1%%)")
    parser.add_argument("--min-coverage", type=float, default=0.03,
                        help="live: union of changed pixels floor (default 3%%)")
    parser.add_argument("--min-transitions", type=int, default=3,
                        help="live: required adjacent changed pairs (default 3)")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.frames < 2:
        raise SystemExit("--frames must be at least 2")
    if args.timeout < 30:
        raise SystemExit("--timeout must be at least 30 seconds")
    if args.device:
        return live(args)
    return offline(args)


if __name__ == "__main__":
    raise SystemExit(main())
