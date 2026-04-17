#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "mcp"))

from motion_surface import (  # noqa: E402
    DEFAULT_MOTION_APP,
    list_commands,
    list_group_names,
    load_motion_surface,
    search_commands,
    summarize_surface,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Inspect Motion's bundled command metadata for MotionKit porting."
    )
    parser.add_argument("--app", default=str(DEFAULT_MOTION_APP), help="Path to Motion.app")
    parser.add_argument("--group", default="", help="Exact group/category name to filter by")
    parser.add_argument("--query", default="", help="Search query across command ids and selectors")
    parser.add_argument("--limit", type=int, default=25, help="Max commands to print for group/query modes")
    parser.add_argument("--summary", action="store_true", help="Print only app/group/count summary")
    args = parser.parse_args()

    surface = load_motion_surface(args.app)

    if args.summary:
        print(json.dumps(summarize_surface(surface), indent=2))
        return 0

    if args.query:
        print(
            json.dumps(
                {
                    "query": args.query,
                    "count": len(search_commands(surface, args.query, args.limit)),
                    "matches": search_commands(surface, args.query, args.limit),
                },
                indent=2,
            )
        )
        return 0

    if args.group:
        commands = list_commands(surface, args.group)
        if args.limit > 0:
            commands = commands[: args.limit]
        print(json.dumps({"group": args.group, "count": len(commands), "commands": commands}, indent=2))
        return 0

    print(
        json.dumps(
            {
                "summary": summarize_surface(surface),
                "groups": list_group_names(surface),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
