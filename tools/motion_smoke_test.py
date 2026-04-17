#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from splicekit_client import SpliceKit  # noqa: E402


def call(client: SpliceKit, method: str, **params):
    result = client.call(method, **params)
    print(f"=== {method} {json.dumps(params, default=str)} ===")
    print(json.dumps(result, indent=2, default=str))
    return result


def host_bundle_id(client: SpliceKit) -> str:
    result = client.call("system.version")
    bundle_id = result.get("host_bundle_id")
    if not bundle_id:
        raise SystemExit(f"FAIL: system.version did not return host_bundle_id: {json.dumps(result, default=str)}")
    return str(bundle_id)


def activate_host(bundle_id: str, delay_seconds: float) -> None:
    subprocess.run(
        ["open", "-b", bundle_id],
        check=True,
    )
    subprocess.run(
        [
            "osascript",
            "-e",
            f"delay {delay_seconds}",
            "-e",
            'tell application "System Events" to keystroke "P" using {command down, shift down}',
        ],
        check=True,
    )


def palette_status(client: SpliceKit) -> dict:
    return call(client, "command.status")


def ensure_palette_visible(client: SpliceKit, visible: bool, delay_seconds: float) -> dict:
    state = call(client, "command.show" if visible else "command.hide")
    state = palette_status(client)
    if bool(state.get("visible")) != visible:
        desired = "visible" if visible else "hidden"
        raise SystemExit(f"FAIL: palette did not become {desired}: {json.dumps(state, default=str)}")
    return state


def verify_palette_hotkey(client: SpliceKit, delay_seconds: float) -> None:
    before = ensure_palette_visible(client, False, delay_seconds)
    after = ensure_palette_visible(client, True, delay_seconds)
    final = ensure_palette_visible(client, False, delay_seconds)

    if bool(before.get("visible")) == bool(after.get("visible")) or bool(before.get("visible")) != bool(final.get("visible")):
        raise SystemExit("FAIL: Cmd+Shift+P did not toggle palette visibility cleanly")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hotkey", action="store_true", help="verify Cmd+Shift+P toggles palette visibility")
    parser.add_argument("--hotkey-delay", type=float, default=0.75, help="delay before and after hotkey press")
    args = parser.parse_args()

    client = SpliceKit()

    call(client, "system.version")
    ensure_palette_visible(client, False, args.hotkey_delay)
    ensure_palette_visible(client, True, args.hotkey_delay)
    ensure_palette_visible(client, False, args.hotkey_delay)
    call(client, "command.search", query="marker", limit=5)

    for action in [
        "Markers/AddMarker",
        "TextTool",
        "Channels/Alpha",
        "GoTo/ProjectStart",
    ]:
        result = call(client, "command.execute", action=action, type="motion_command")
        if result.get("status") != "ok":
            print(f"FAIL: {action} did not return status=ok", file=sys.stderr)
            return 1

    if args.hotkey:
        verify_palette_hotkey(client, delay_seconds=args.hotkey_delay)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
