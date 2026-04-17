from __future__ import annotations

import plistlib
import re
from pathlib import Path
from typing import Any

DEFAULT_MOTION_APP = Path("/Applications/Motion.app")


def _normalize_text(value: Any) -> str:
    text = str(value or "")
    return " ".join(re.sub(r"[^0-9A-Za-z]+", " ", text).lower().split())


def _camel_case_to_words(value: str) -> str:
    if not value:
        return ""

    result: list[str] = []
    for index, current in enumerate(value):
        previous = value[index - 1] if index > 0 else ""
        next_char = value[index + 1] if index + 1 < len(value) else ""

        insert_space = False
        if index > 0:
            current_upper = current.isupper()
            previous_lower = previous.islower()
            previous_digit = previous.isdigit()
            current_digit = current.isdigit()
            next_lower = next_char.islower()

            if (
                (current_upper and previous_lower)
                or (current_upper and previous.isupper() and next_lower)
                or (current_digit and previous.isalpha())
                or (current.isalpha() and previous_digit)
            ):
                insert_space = True

        if insert_space:
            result.append(" ")
        result.append(current)

    spaced = "".join(result).replace("&", " and ").strip()
    if spaced == "Playfrom Start":
        return "Play From Start"
    return spaced


def _display_name(command_id: str) -> str:
    if not command_id:
        return ""

    parts = [_camel_case_to_words(part).strip() for part in command_id.split("/")]
    return " / ".join(part for part in parts if part)


def _selector_words(selector: str) -> str:
    return _camel_case_to_words(selector.replace(":", "")).strip()


def _command_search_blob(command: dict[str, Any]) -> dict[str, str | list[str]]:
    groups = [str(group) for group in command.get("groups", [])]
    return {
        "id": _normalize_text(command.get("id", "")),
        "display_name": _normalize_text(command.get("display_name", "")),
        "selector": _normalize_text(command.get("selector", "")),
        "selector_words": _normalize_text(command.get("selector_words", "")),
        "category": _normalize_text(command.get("category", "")),
        "groups": [_normalize_text(group) for group in groups],
    }


def _command_sort_key(command: dict[str, Any]) -> tuple[str, str]:
    return (str(command.get("display_name", "")).casefold(), str(command.get("id", "")).casefold())


def _search_score(command: dict[str, Any], tokens: list[str]) -> int:
    blob = _command_search_blob(command)
    values = [
        blob["id"],
        blob["display_name"],
        blob["selector"],
        blob["selector_words"],
        blob["category"],
        *blob["groups"],
    ]
    if not all(any(token in value for value in values) for token in tokens):
        return -1

    joined_query = " ".join(tokens)
    score = 0
    if joined_query == blob["id"]:
        score += 140
    if joined_query == blob["display_name"]:
        score += 130
    if joined_query == blob["selector"] or joined_query == blob["selector_words"]:
        score += 120

    if blob["id"].startswith(joined_query):
        score += 80
    if blob["display_name"].startswith(joined_query):
        score += 70
    if blob["selector_words"].startswith(joined_query):
        score += 60

    for token in tokens:
        if token in blob["id"]:
            score += 18
        if token in blob["display_name"]:
            score += 16
        if token in blob["selector"] or token in blob["selector_words"]:
            score += 14
        if token in blob["category"]:
            score += 6
        if any(token in group for group in blob["groups"]):
            score += 4

    score += max(0, 12 - len(command.get("id", "")))
    return score


def _load_plist(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(path)
    data = plistlib.loads(path.read_bytes())
    if not isinstance(data, dict):
        raise ValueError(f"Expected dict plist at {path}")
    return data


def load_motion_surface(app_path: str | Path = DEFAULT_MOTION_APP) -> dict[str, Any]:
    app = Path(app_path).expanduser()
    resources = app / "Contents" / "Resources"
    info = _load_plist(app / "Contents" / "Info.plist")
    commands_raw = _load_plist(resources / "NSProCommands.plist")
    groups_raw = _load_plist(resources / "NSProCommandGroups.plist")
    extra_raw = _load_plist(resources / "NSProCommandsAdditional.plist")

    reverse_groups: dict[str, list[str]] = {}
    groups: dict[str, dict[str, Any]] = {}
    for group_name, payload in sorted(groups_raw.items()):
        command_ids = [str(command_id) for command_id in payload.get("commands", [])]
        groups[group_name] = {
            "color_index": payload.get("color index"),
            "commands": command_ids,
            "count": len(command_ids),
        }
        for command_id in command_ids:
            reverse_groups.setdefault(command_id, []).append(group_name)

    merged_commands: dict[str, dict[str, Any]] = {}
    command_sources: dict[str, str] = {}
    for source_name, raw_commands in (("base", commands_raw), ("additional", extra_raw)):
        for command_id, payload in raw_commands.items():
            if not isinstance(payload, dict):
                continue
            existing = dict(merged_commands.get(command_id, {}))
            existing.update(payload)
            merged_commands[command_id] = existing
            previous_source = command_sources.get(command_id)
            if previous_source and previous_source != source_name:
                command_sources[command_id] = "base+additional"
            else:
                command_sources[command_id] = source_name

    commands: list[dict[str, Any]] = []
    for command_id, payload in sorted(merged_commands.items()):
        memberships = reverse_groups.get(command_id, [])
        category = command_id.split("/", 1)[0] if "/" in command_id else (memberships[0] if memberships else "Ungrouped")
        display_name = _display_name(command_id)
        selector = payload.get("downSelector", "")
        commands.append(
            {
                "id": command_id,
                "display_name": display_name,
                "category": category,
                "groups": memberships,
                "selector": selector,
                "selector_words": _selector_words(str(selector)),
                "tag": payload.get("downTag"),
                "repeats": bool(payload.get("downRepeats", 0)),
                "source": command_sources.get(command_id, "base"),
            }
        )

    commands.sort(key=_command_sort_key)

    document_types = []
    for entry in info.get("CFBundleDocumentTypes", []):
        document_types.append(
            {
                "role": entry.get("CFBundleTypeRole"),
                "extensions": entry.get("CFBundleTypeExtensions", []),
                "content_types": entry.get("LSItemContentTypes", []),
                "document_class": entry.get("NSDocumentClass"),
            }
        )

    return {
        "app": {
            "path": str(app),
            "name": info.get("CFBundleName"),
            "display_name": info.get("CFBundleDisplayName"),
            "bundle_id": info.get("CFBundleIdentifier"),
            "executable": info.get("CFBundleExecutable"),
            "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"),
            "principal_class": info.get("NSPrincipalClass"),
            "document_types": document_types,
        },
        "counts": {
            "commands": len(commands),
            "base_commands": len(commands_raw),
            "groups": len(groups),
            "additional_commands": len(extra_raw),
            "merged_commands": len(merged_commands),
        },
        "groups": groups,
        "commands": commands,
    }


def summarize_surface(surface: dict[str, Any]) -> dict[str, Any]:
    return {
        "app": surface["app"],
        "counts": surface["counts"],
        "group_names": sorted(surface["groups"].keys()),
    }


def list_group_names(surface: dict[str, Any]) -> list[str]:
    return sorted(surface["groups"].keys())


def list_commands(surface: dict[str, Any], group: str = "") -> list[dict[str, Any]]:
    if not group:
        return list(surface["commands"])
    normalized = group.casefold()
    return [
        command
        for command in surface["commands"]
        if any(name.casefold() == normalized for name in command["groups"])
        or command["category"].casefold() == normalized
    ]


def search_commands(surface: dict[str, Any], query: str, limit: int = 25) -> list[dict[str, Any]]:
    tokens = [token for token in _normalize_text(query).split() if token]
    if not tokens:
        return surface["commands"][: max(limit, 0) or 25]

    ranked: list[tuple[int, dict[str, Any]]] = []
    for command in surface["commands"]:
        score = _search_score(command, tokens)
        if score < 0:
            continue
        ranked.append((score, command))

    ranked.sort(key=lambda item: (-item[0], *_command_sort_key(item[1])))
    if limit <= 0:
        return [command for _, command in ranked]
    return [command for _, command in ranked[:limit]]


def find_command(surface: dict[str, Any], identifier: str) -> dict[str, Any] | None:
    normalized = _normalize_text(identifier)
    if not normalized:
        return None

    exact_matches = []
    for command in surface["commands"]:
        blob = _command_search_blob(command)
        if normalized in {
            blob["id"],
            blob["display_name"],
            blob["selector"],
            blob["selector_words"],
        }:
            exact_matches.append(command)

    if len(exact_matches) == 1:
        return exact_matches[0]
    if exact_matches:
        exact_matches.sort(key=_command_sort_key)
        return exact_matches[0]

    matches = search_commands(surface, identifier, limit=1)
    return matches[0] if matches else None
