#!/usr/bin/env python3
"""The iOS accessibility-ID contract and its static/live audits.

`docs/ios/ARCHITECTURE.md` fixes the stable accessibility identifiers the UI must
expose. Assertions use the whole contract set, not a convenient subset: a screen
that forgets one identifier fails the audit instead of silently passing.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import re
from typing import Any, Iterable

try:
    from . import qa_paths
except ImportError:  # pragma: no cover
    import qa_paths  # type: ignore[no-redef]

CONTRACT_UI_IDS: tuple[str, ...] = (
    "wm.library",
    "wm.import",
    "wm.search",
    "wm.preview",
    "wm.settings",
    "wm.workshop",
    "wm.export",
)

ID_PATTERN = re.compile(r"(?<![A-Za-z0-9_.])wm\.[A-Za-z0-9][A-Za-z0-9_.-]*")


def identifiers(text: str) -> list[str]:
    """Every distinct ``wm.*`` identifier in an accessibility tree or source text."""
    return sorted(set(ID_PATTERN.findall(text or "")))


def missing_contract_ids(found: Iterable[str]) -> list[str]:
    present = set(found)
    return [identifier for identifier in CONTRACT_UI_IDS if identifier not in present]


@dataclass
class UIAudit:
    found: list[str] = field(default_factory=list)
    missing: list[str] = field(default_factory=list)
    source_bytes: int = 0
    note: str = ""

    @property
    def ok(self) -> bool:
        return not self.missing

    def as_dict(self) -> dict:
        return {
            "required": list(CONTRACT_UI_IDS),
            "found": self.found,
            "missing": self.missing,
            "source_bytes": self.source_bytes,
            "note": self.note,
        }


def static_scan(root: str | Path | None = None) -> dict[str, list[str]]:
    """Map contract IDs to the Swift files that mention them."""
    directory = Path(root) if root else qa_paths.IOS_SOURCES
    occurrences: dict[str, list[str]] = {}
    if not directory.is_dir():
        return occurrences
    for path in sorted(directory.rglob("*.swift")):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for identifier in identifiers(text):
            try:
                display = path.relative_to(qa_paths.ROOT).as_posix()
            except ValueError:
                display = str(path)
            occurrences.setdefault(identifier, []).append(display)
    return occurrences


def static_audit(root: str | Path | None = None) -> UIAudit:
    occurrences = static_scan(root)
    found = sorted(occurrences)
    return UIAudit(
        found=found,
        missing=missing_contract_ids(found),
        source_bytes=sum(len(paths) for paths in occurrences.values()),
        note="static scan of iOS/Sources; runtime presence is checked only on a live run",
    )


def live_audit(session: Any, *, bundle_id: str | None = None,
               deep: bool = False) -> UIAudit:
    """Read the current screen and check every contract identifier is present."""
    params: dict[str, Any] = {"visible_only": True, "max_children": 50}
    if bundle_id:
        params["bundle_id"] = bundle_id
    result = session.page_source(**params)
    source = str(result.get("source", ""))
    found = identifiers(source)
    missing = missing_contract_ids(found)
    note = "visible page_source only"
    if deep and missing:
        recovered = []
        for identifier in list(missing):
            try:
                element = session.find_element(identifier)
            except Exception:  # noqa: BLE001 - an audit must not hide earlier findings
                continue
            if element.get("exists"):
                recovered.append(identifier)
                missing.remove(identifier)
        if recovered:
            found.extend(recovered)
            found = sorted(set(found))
            note += f"; recovered by find_element: {', '.join(recovered)}"
    return UIAudit(found=found, missing=missing,
                   source_bytes=len(source.encode("utf-8")), note=note)
