#!/usr/bin/env python3
"""Inventory local Copilot chat sessions across every VS Code flavor.

Cloud session store only covers recent synced chats, and only for the
account/app that uploaded them. Older history — and chats from the other
VS Code install (Stable vs Insiders) — lives on disk as JSONL under each
flavor's user-data directory.

This helper is what makes Dream flavor-agnostic: a dream started in
Insiders still sees Stable's local history, and vice versa.

Stdlib only. Prints a markdown digest to stdout; progress goes to stderr.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import traceback
import urllib.parse
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable

# VS Code family is scanned by default. Cursor is discovered and available
# via --flavors cursor, but not included in --flavors all (different product).
VSCODE_FAMILY = (
    "Code",
    "Code - Insiders",
    "Code - Exploration",
    "VSCodium",
)
OPTIONAL_APPS = ("Cursor",)
FLAVOR_APP_NAMES = VSCODE_FAMILY + OPTIONAL_APPS

FLAVOR_ALIASES = {
    "all": None,
    "current": "current",
    "none": "none",
    "stable": "Code",
    "code": "Code",
    "insiders": "Code - Insiders",
    "insider": "Code - Insiders",
    "exploration": "Code - Exploration",
    "vscodium": "VSCodium",
    "cursor": "Cursor",
}

DEFAULT_MAX_FILE_BYTES = 10 * 1024 * 1024
DEFAULT_MAX_SESSIONS = 80
DEFAULT_MAX_TEXTS = 2
DEFAULT_MAX_LINES = 80
DEFAULT_MAX_WORKSPACES = 200


def eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def flavor_label(app_name: str) -> str:
    return {
        "Code": "stable",
        "Code - Insiders": "insiders",
        "Code - Exploration": "exploration",
        "VSCodium": "vscodium",
        "Cursor": "cursor",
    }.get(app_name, app_name.lower().replace(" ", "-"))


def candidate_user_dirs() -> list[tuple[str, Path]]:
    """Return (app_name, User-dir) pairs that exist on this machine."""
    home = Path.home()
    found: list[tuple[str, Path]] = []
    seen: set[Path] = set()

    search_roots = [home / "Library" / "Application Support", home / ".config"]
    appdata = os.environ.get("APPDATA")
    if appdata:
        search_roots.append(Path(appdata))

    for root in search_roots:
        for name in FLAVOR_APP_NAMES:
            user_dir = root / name / "User"
            try:
                resolved = user_dir.resolve()
            except OSError:
                continue
            if resolved in seen or not user_dir.is_dir():
                continue
            seen.add(resolved)
            found.append((name, user_dir))

    extra = os.environ.get("VSCODE_USER_DATA_DIR")
    if extra:
        user_dir = Path(extra) / "User"
        if user_dir.is_dir():
            resolved = user_dir.resolve()
            if resolved not in seen:
                found.append(("custom", user_dir))

    return found


def detect_current_app_name() -> str | None:
    """Best-effort: which flavor is running this chat?"""
    hook = os.environ.get("VSCODE_IPC_HOOK", "")
    portable = os.environ.get("VSCODE_PORTABLE", "")
    blob = f"{hook} {portable}".lower()
    if "code - insiders" in blob or "code-insiders" in blob:
        return "Code - Insiders"
    if "code - exploration" in blob or "code-exploration" in blob:
        return "Code - Exploration"
    if "vscodium" in blob:
        return "VSCodium"
    if "cursor" in blob:
        return "Cursor"
    if "code" in blob:
        return "Code"
    return None


def parse_window(raw: str) -> timedelta | None:
    text = (raw or "").strip().lower()
    if not text or text in {"all", "everything", "forever"}:
        return None
    match = re.fullmatch(r"(\d+)\s*(day|days|week|weeks|month|months|year|years)", text)
    if not match:
        raise SystemExit(
            f"Unrecognized --window {raw!r}. Use e.g. '7 days', '1 year', or 'all'."
        )
    n = int(match.group(1))
    unit = match.group(2)
    days = {
        "day": n,
        "days": n,
        "week": n * 7,
        "weeks": n * 7,
        "month": n * 30,
        "months": n * 30,
        "year": n * 365,
        "years": n * 365,
    }[unit]
    return timedelta(days=days)


def file_uri_to_path(uri: str) -> str:
    if not uri:
        return ""
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme and parsed.scheme != "file":
        return uri
    path = urllib.parse.unquote(parsed.path or uri)
    # Windows file URIs look like /C:/Users/...
    if re.match(r"^/[A-Za-z]:/", path):
        path = path[1:]
    return path


def workspace_target(workspace_json: Path) -> tuple[str, str]:
    """Return (kind, path) from workspace.json."""
    try:
        data = json.loads(workspace_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return "unknown", ""
    if not isinstance(data, dict):
        return "unknown", ""
    if "folder" in data:
        return "folder", file_uri_to_path(str(data.get("folder") or ""))
    if "workspace" in data:
        return "workspace", file_uri_to_path(str(data.get("workspace") or ""))
    return "unknown", ""


def path_matches(path: str, needles: Iterable[str]) -> bool:
    hay = path.lower()
    return any(n.lower() in hay for n in needles if n)


def ms_to_dt(ms: object) -> datetime | None:
    try:
        value = float(ms)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    if value > 1e12:
        value /= 1000.0
    try:
        return datetime.fromtimestamp(value, tz=timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None


def extract_session(
    path: Path,
    max_texts: int,
    max_lines: int,
    max_bytes: int,
) -> dict:
    size = path.stat().st_size
    header: dict = {
        "sessionId": path.stem,
        "creationDate": None,
        "initialLocation": None,
        "mtime": datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc),
        "bytes": size,
        "oversized": size > max_bytes,
        "texts": [],
    }
    try:
        with path.open(encoding="utf-8", errors="replace") as fh:
            first = fh.readline()
            try:
                obj = json.loads(first)
            except json.JSONDecodeError:
                return header
            v = obj.get("v") if isinstance(obj, dict) else None
            if obj.get("kind") == 0 and isinstance(v, dict):
                header["sessionId"] = v.get("sessionId") or header["sessionId"]
                header["creationDate"] = ms_to_dt(v.get("creationDate"))
                header["initialLocation"] = v.get("initialLocation")
            if header["oversized"]:
                return header
            texts: list[str] = []
            for i, line in enumerate(fh):
                if i >= max_lines or len(texts) >= max_texts:
                    break
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("kind") != 2:
                    continue
                payload = rec.get("v")
                items = payload if isinstance(payload, list) else [payload]
                for item in items:
                    if not isinstance(item, dict):
                        continue
                    msg = item.get("message")
                    text = None
                    if isinstance(msg, dict):
                        text = msg.get("text")
                    elif isinstance(msg, str):
                        text = msg
                    if not isinstance(text, str):
                        continue
                    text = " ".join(text.split())
                    if len(text) < 8:
                        continue
                    texts.append(text[:200] + ("…" if len(text) > 200 else ""))
                    if len(texts) >= max_texts:
                        break
            header["texts"] = texts
    except OSError as exc:
        header["error"] = str(exc)
    return header


def list_session_files(directory: Path) -> list[Path]:
    if not directory.is_dir():
        return []
    files = [
        p
        for p in directory.iterdir()
        if p.is_file() and p.suffix.lower() in {".jsonl", ".json"}
    ]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return files


def collect(
    flavors: str,
    window: timedelta | None,
    workspaces: list[str],
    excludes: list[str],
    max_file_bytes: int,
    max_sessions: int,
    inventory_only: bool,
) -> dict:
    now = datetime.now(tz=timezone.utc)
    cutoff = (now - window) if window else None
    flavor_key = (flavors or "all").strip().lower()
    wanted_app = FLAVOR_ALIASES.get(flavor_key, flavors)
    if wanted_app == "none":
        return {
            "flavors_found": [],
            "workspaces": [],
            "sessions": [],
            "skipped_oversized": 0,
            "cutoff": cutoff.isoformat() if cutoff else None,
        }
    if wanted_app == "current":
        detected = detect_current_app_name()
        wanted_app = detected or "Code"

    roots = candidate_user_dirs()
    if flavor_key in {"all", ""}:
        roots = [(name, path) for name, path in roots if name in VSCODE_FAMILY]
    elif wanted_app not in {None, "all"}:
        roots = [(name, path) for name, path in roots if name == wanted_app]

    workspace_rows: list[dict] = []
    session_rows: list[dict] = []
    skipped_oversized = 0

    for app_name, user_dir in roots:
        label = flavor_label(app_name)
        storage = user_dir / "workspaceStorage"
        if storage.is_dir():
            for entry in sorted(storage.iterdir()):
                if not entry.is_dir():
                    continue
                wj = entry / "workspace.json"
                kind, target = workspace_target(wj) if wj.is_file() else ("unknown", "")
                if workspaces and not path_matches(target, workspaces):
                    continue
                if excludes and path_matches(target, excludes):
                    continue
                chats_dir = entry / "chatSessions"
                files = list_session_files(chats_dir)
                if not files:
                    continue
                latest_mtime = max(p.stat().st_mtime for p in files)
                latest_dt = datetime.fromtimestamp(latest_mtime, tz=timezone.utc)
                in_window_files = files
                if cutoff:
                    in_window_files = [
                        p
                        for p in files
                        if datetime.fromtimestamp(p.stat().st_mtime, tz=timezone.utc)
                        >= cutoff
                    ]
                if not in_window_files:
                    continue
                workspace_rows.append(
                    {
                        "flavor": label,
                        "app": app_name,
                        "kind": kind,
                        "path": target or f"(unresolved {entry.name[:12]})",
                        "sessions": len(files),
                        "in_window": len(in_window_files),
                        "latest": latest_dt,
                    }
                )
                if inventory_only:
                    continue
                for path in in_window_files:
                    rec = extract_session(
                        path,
                        max_texts=DEFAULT_MAX_TEXTS,
                        max_lines=DEFAULT_MAX_LINES,
                        max_bytes=max_file_bytes,
                    )
                    created = rec["creationDate"] or rec["mtime"]
                    if cutoff and created < cutoff:
                        continue
                    if rec["oversized"]:
                        skipped_oversized += 1
                    session_rows.append(
                        {
                            "flavor": label,
                            "app": app_name,
                            "workspace": target or "(unknown workspace)",
                            "sessionId": rec["sessionId"],
                            "created": created,
                            "bytes": rec["bytes"],
                            "oversized": rec["oversized"],
                            "texts": rec["texts"],
                            "location": rec["initialLocation"],
                        }
                    )

        empty_dir = user_dir / "globalStorage" / "emptyWindowChatSessions"
        empty_files = list_session_files(empty_dir)
        if empty_files:
            if excludes and path_matches("(empty-window)", excludes):
                pass
            elif workspaces and not path_matches("(empty-window)", workspaces):
                pass
            else:
                latest_dt = datetime.fromtimestamp(
                    max(p.stat().st_mtime for p in empty_files), tz=timezone.utc
                )
                in_window_files = empty_files
                if cutoff:
                    in_window_files = [
                        p
                        for p in empty_files
                        if datetime.fromtimestamp(p.stat().st_mtime, tz=timezone.utc)
                        >= cutoff
                    ]
                if not in_window_files:
                    continue
                workspace_rows.append(
                    {
                        "flavor": label,
                        "app": app_name,
                        "kind": "empty-window",
                        "path": "(empty window)",
                        "sessions": len(empty_files),
                        "in_window": len(in_window_files),
                        "latest": latest_dt,
                    }
                )
                if not inventory_only:
                    for path in in_window_files:
                        rec = extract_session(
                            path,
                            max_texts=DEFAULT_MAX_TEXTS,
                            max_lines=DEFAULT_MAX_LINES,
                            max_bytes=max_file_bytes,
                        )
                        created = rec["creationDate"] or rec["mtime"]
                        if cutoff and created < cutoff:
                            continue
                        if rec["oversized"]:
                            skipped_oversized += 1
                        session_rows.append(
                            {
                                "flavor": label,
                                "app": app_name,
                                "workspace": "(empty window)",
                                "sessionId": rec["sessionId"],
                                "created": created,
                                "bytes": rec["bytes"],
                                "oversized": rec["oversized"],
                                "texts": rec["texts"],
                                "location": rec["initialLocation"],
                            }
                        )

    workspace_rows.sort(key=lambda r: r["latest"], reverse=True)
    session_rows.sort(key=lambda r: r["created"] or now)
    if len(session_rows) > max_sessions:
        session_rows = session_rows[-max_sessions:]

    return {
        "flavors_found": [
            {"app": name, "label": flavor_label(name), "user_dir": str(path)}
            for name, path in roots
        ],
        "workspaces": workspace_rows[:DEFAULT_MAX_WORKSPACES],
        "sessions": session_rows,
        "skipped_oversized": skipped_oversized,
        "cutoff": cutoff.isoformat() if cutoff else None,
        "truncated_workspaces": max(0, len(workspace_rows) - DEFAULT_MAX_WORKSPACES),
    }


def fmt_dt(value: datetime | None) -> str:
    if not value:
        return "?"
    return value.astimezone(timezone.utc).strftime("%Y-%m-%d")


def render_markdown(data: dict, window_label: str) -> str:
    lines: list[str] = []
    flavors = data["flavors_found"]
    workspaces = data["workspaces"]
    sessions = data["sessions"]
    flavor_counts: dict[str, int] = {}
    for row in workspaces:
        flavor_counts[row["flavor"]] = flavor_counts.get(row["flavor"], 0) + row["in_window"]

    lines.append("═══ LOCAL SESSIONS (all VS Code flavors) ═══")
    lines.append(f"Window: {window_label}")
    if flavors:
        listed = ", ".join(f"{f['app']} ({f['label']})" for f in flavors)
        lines.append(f"Flavors found: {listed}")
    else:
        lines.append("Flavors found: none")
    count_bits = ", ".join(f"{k} {v}" for k, v in sorted(flavor_counts.items())) or "0"
    lines.append(
        f"Sessions in window: {sum(flavor_counts.values())} ({count_bits})"
    )
    lines.append(f"Workspaces with chats: {len(workspaces)}")
    if data.get("truncated_workspaces"):
        lines.append(f"Workspace list truncated by {data['truncated_workspaces']}")
    lines.append(f"Digest sessions: {len(sessions)} (capped)")
    lines.append(f"Skipped oversized bodies: {data['skipped_oversized']}")
    lines.append("")
    lines.append("─── WORKSPACES ───")
    if not workspaces:
        lines.append("(none)")
    for row in workspaces:
        lines.append(
            f"{fmt_dt(row['latest'])}  {row['flavor']:<12}  "
            f"{row['in_window']}/{row['sessions']}  {row['path']}"
        )
    if sessions:
        lines.append("")
        lines.append("─── DIGEST ───")
        current_ws = None
        for row in sessions:
            key = (row["flavor"], row["workspace"])
            if key != current_ws:
                current_ws = key
                lines.append("")
                lines.append(f"{row['flavor']}  {row['workspace']}")
            extra = "  [oversized — header only]" if row["oversized"] else ""
            lines.append(f"  {fmt_dt(row['created'])}  {row['sessionId']}{extra}")
            if row["texts"]:
                for text in row["texts"]:
                    lines.append(f"    - {text}")
            elif row["oversized"]:
                lines.append("    - (body skipped; file too large)")
    lines.append("")
    return "\n".join(lines)


def run_self_test() -> int:
    eprint("=== step: self-test fixture setup ===")
    failures = 0

    def check(cond: bool, label: str) -> None:
        nonlocal failures
        if cond:
            eprint(f"[PASS] {label}")
        else:
            eprint(f"[FAIL] {label}")
            failures += 1

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        stable_user = tmp_path / "Code" / "User"
        insiders_user = tmp_path / "Code - Insiders" / "User"
        for user, folder, sid, created_ms, prompt in (
            (
                stable_user,
                "/tmp/fake-stable-repo",
                "11111111-1111-1111-1111-111111111111",
                1_700_000_000_000,
                "please always run tests yourself in the stable app",
            ),
            (
                insiders_user,
                "/tmp/fake-insiders-repo",
                "22222222-2222-2222-2222-222222222222",
                1_720_000_000_000,
                "change the winner name in the insiders workspace",
            ),
        ):
            ws_hash = "abc" if "stable" in folder else "def"
            ws_dir = user / "workspaceStorage" / ws_hash
            chats = ws_dir / "chatSessions"
            chats.mkdir(parents=True)
            (ws_dir / "workspace.json").write_text(
                json.dumps({"folder": "file://" + folder}), encoding="utf-8"
            )
            header = {
                "kind": 0,
                "v": {
                    "sessionId": sid,
                    "creationDate": created_ms,
                    "initialLocation": "panel",
                },
            }
            turn = {
                "kind": 2,
                "v": [
                    {
                        "timestamp": created_ms + 1000,
                        "message": {"text": prompt},
                    }
                ],
            }
            (chats / f"{sid}.jsonl").write_text(
                json.dumps(header) + "\n" + json.dumps(turn) + "\n",
                encoding="utf-8",
            )

        # Monkeypatch discovery to the fixture roots only.
        original = candidate_user_dirs

        def fake_dirs() -> list[tuple[str, Path]]:
            return [("Code", stable_user), ("Code - Insiders", insiders_user)]

        globals()["candidate_user_dirs"] = lambda: fake_dirs()  # type: ignore[assignment]
        try:
            data = collect(
                flavors="all",
                window=None,
                workspaces=[],
                excludes=[],
                max_file_bytes=DEFAULT_MAX_FILE_BYTES,
                max_sessions=DEFAULT_MAX_SESSIONS,
                inventory_only=False,
            )
            labels = {f["label"] for f in data["flavors_found"]}
            check(labels == {"stable", "insiders"}, "discovers both flavors")
            check(len(data["workspaces"]) == 2, "inventories both workspaces")
            texts = " ".join(
                t for row in data["sessions"] for t in row["texts"]
            )
            check("stable app" in texts, "reads stable user text")
            check("insiders workspace" in texts, "reads insiders user text")

            scoped = collect(
                flavors="all",
                window=None,
                workspaces=["fake-stable-repo"],
                excludes=[],
                max_file_bytes=DEFAULT_MAX_FILE_BYTES,
                max_sessions=DEFAULT_MAX_SESSIONS,
                inventory_only=False,
            )
            check(
                len(scoped["workspaces"]) == 1
                and "fake-stable-repo" in scoped["workspaces"][0]["path"],
                "--workspace filters to one repo",
            )

            excluded = collect(
                flavors="all",
                window=None,
                workspaces=[],
                excludes=["fake-insiders-repo"],
                max_file_bytes=DEFAULT_MAX_FILE_BYTES,
                max_sessions=DEFAULT_MAX_SESSIONS,
                inventory_only=False,
            )
            check(
                all("insiders" not in r["path"] for r in excluded["workspaces"]),
                "--exclude drops matching workspaces",
            )

            stable_only = collect(
                flavors="stable",
                window=None,
                workspaces=[],
                excludes=[],
                max_file_bytes=DEFAULT_MAX_FILE_BYTES,
                max_sessions=DEFAULT_MAX_SESSIONS,
                inventory_only=True,
            )
            check(
                {f["label"] for f in stable_only["flavors_found"]} == {"stable"},
                "--flavors stable limits discovery",
            )
        finally:
            globals()["candidate_user_dirs"] = original  # type: ignore[assignment]

    check(parse_window("1 year") == timedelta(days=365), "parses 1 year window")
    check(parse_window("all") is None, "parses all as unbounded")
    try:
        parse_window("last tuesday")
        check(False, "rejects unknown window")
    except SystemExit:
        check(True, "rejects unknown window")

    eprint("=== step: self-test complete ===")
    if failures:
        eprint(f"{failures} check(s) failed")
        return 1
    eprint("All self-test checks passed")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Scan local Copilot chatSessions across VS Code flavors."
    )
    parser.add_argument(
        "--window",
        default="7 days",
        help="How far back to include (e.g. '7 days', '1 year', 'all')",
    )
    parser.add_argument(
        "--flavors",
        default="all",
        help="all | current | stable | insiders | none",
    )
    parser.add_argument(
        "--workspace",
        action="append",
        default=[],
        help="Only include workspaces whose path contains this string. Repeatable.",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="Skip workspaces whose path contains this string. Repeatable.",
    )
    parser.add_argument(
        "--max-file-bytes",
        type=int,
        default=DEFAULT_MAX_FILE_BYTES,
        help="Read headers only for JSONL larger than this (default 10MiB)",
    )
    parser.add_argument(
        "--max-sessions",
        type=int,
        default=DEFAULT_MAX_SESSIONS,
        help="Cap digest rows (default 80, most recent after chronological sort)",
    )
    parser.add_argument(
        "--inventory",
        action="store_true",
        help="List workspaces only; do not open session bodies",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit JSON instead of markdown",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run fixture checks and exit",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.self_test:
        return run_self_test()

    eprint("=== step: discovering VS Code user-data dirs ===")
    try:
        window = parse_window(args.window)
    except SystemExit as exc:
        eprint(str(exc))
        return 2

    eprint(f"=== step: scanning local chatSessions (flavors={args.flavors}) ===")
    try:
        data = collect(
            flavors=args.flavors,
            window=window,
            workspaces=args.workspace,
            excludes=args.exclude,
            max_file_bytes=args.max_file_bytes,
            max_sessions=args.max_sessions,
            inventory_only=args.inventory,
        )
    except Exception:
        traceback.print_exc()
        return 1

    eprint("=== step: rendering digest ===")
    if args.json:
        def default(obj: object) -> object:
            if isinstance(obj, datetime):
                return obj.isoformat()
            return str(obj)

        print(json.dumps(data, default=default, indent=2))
    else:
        print(render_markdown(data, args.window))
    return 0


if __name__ == "__main__":
    sys.exit(main())
