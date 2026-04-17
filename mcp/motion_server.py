#!/usr/bin/env python3
"""
MotionKit MCP Server.

Motion-first MCP entrypoint for the MotionKit fork. Unlike the original
SpliceKit server, this one starts from the parts that already transfer well
to Apple Motion: runtime introspection, ObjC method calls, menu execution,
dialog handling, and command-surface discovery from Motion's own plists.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path


def _import_fastmcp():
    try:
        from mcp.server.fastmcp import FastMCP as fastmcp
        return fastmcp
    except ModuleNotFoundError:
        original_sys_path = list(sys.path)
        try:
            filtered_sys_path = []
            cwd = Path.cwd().resolve()
            for entry in original_sys_path:
                base = Path(entry or cwd).resolve()
                # Repo-local mcp/server.py shadows the installed SDK package.
                if (base / "mcp" / "server.py").exists():
                    continue
                filtered_sys_path.append(entry)
            sys.path = filtered_sys_path
            from mcp.server.fastmcp import FastMCP as fastmcp
            return fastmcp
        finally:
            sys.path = original_sys_path


FastMCP = _import_fastmcp()

from motion_surface import (
    DEFAULT_MOTION_APP,
    find_command,
    list_commands,
    list_group_names,
    load_motion_surface,
    search_commands as search_motion_surface,
    summarize_surface,
)

SPLICEKIT_HOST = os.environ.get("MOTIONKIT_HOST", "127.0.0.1")
SPLICEKIT_PORT = int(os.environ.get("MOTIONKIT_PORT", "9878"))
MOTION_APP_PATH = os.environ.get("MOTIONKIT_APP_PATH", str(DEFAULT_MOTION_APP))
MOTION_HOST_BUNDLE_IDS = {"com.apple.motionapp", "com.motionkit.motionapp"}

mcp = FastMCP(
    "motionkit",
    instructions="""Direct in-process control of Apple Motion via injected MotionKit dylib.
Connects to a JSON-RPC server running inside the Motion process.

Use this server for the Motion port's stable foundation:
1. bridge_status() to verify Motion is running with MotionKit loaded
2. motion_app_info(), motion_list_command_groups(), and motion_search_commands() to inspect Motion's command surface
3. motion_search_palette_commands() and motion_execute_command() to use the live MotionKit command palette registry
4. get_classes(), get_methods(), and call_method_with_args() to map Motion's live ObjC runtime
5. execute_menu_command(), list_menus(), and dialog tools to automate commands before dedicated adapters exist

This server intentionally avoids exposing FCP-only timeline tools until Motion-specific adapters are implemented.
""",
)


class BridgeConnection:
    def __init__(self) -> None:
        self.sock: socket.socket | None = None
        self._buf = b""
        self._id = 0

    def ensure_connected(self) -> None:
        if self.sock is None:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(30)
            try:
                sock.connect((SPLICEKIT_HOST, SPLICEKIT_PORT))
            except Exception:
                sock.close()
                self.sock = None
                raise
            self.sock = sock
            self._buf = b""

    def call(self, method: str, params_dict=None, **params) -> dict:
        if isinstance(params_dict, dict):
            params = {**params_dict, **params}
        try:
            self.ensure_connected()
        except (ConnectionRefusedError, OSError) as exc:
            return {
                "error": (
                    f"Cannot connect to MotionKit at {SPLICEKIT_HOST}:{SPLICEKIT_PORT}. "
                    f"Is the modded Motion app running? Error: {exc}"
                )
            }

        self._id += 1
        request = json.dumps(
            {"jsonrpc": "2.0", "method": method, "params": params, "id": self._id}
        )
        try:
            assert self.sock is not None
            self.sock.sendall(request.encode() + b"\n")
            while b"\n" not in self._buf:
                chunk = self.sock.recv(16777216)
                if not chunk:
                    self.sock = None
                    return {"error": "Connection closed by MotionKit"}
                self._buf += chunk
            line, self._buf = self._buf.split(b"\n", 1)
            response = json.loads(line)
            if "error" in response:
                return {"error": response["error"]}
            return response.get("result", {})
        except Exception as exc:
            self.sock = None
            return {"error": f"Bridge communication error: {exc}"}


bridge = BridgeConnection()


def _err(response: dict) -> bool:
    return "error" in response


def _fmt(response: dict) -> str:
    return json.dumps(response, indent=2, default=str)


def _is_motion_host(response: dict) -> bool:
    return bool(response.get("motion_host")) and response.get("host_bundle_id") in MOTION_HOST_BUNDLE_IDS


def _call_or_error(method: str, **params) -> str:
    response = bridge.call(method, **params)
    if _err(response):
        return f"Error: {response.get('error', response)}"
    return _fmt(response)


def _wait_for_bridge(timeout_seconds: float, require_ready: bool, poll_interval: float) -> dict:
    deadline = time.monotonic() + max(timeout_seconds, 0.0)
    interval = max(poll_interval, 0.05)
    last_response: dict = {"error": "bridge not checked"}

    while True:
        response = bridge.call("system.ping")
        last_response = response
        if not _err(response):
            if not _is_motion_host(response):
                last_response = {
                    "error": (
                        "Connected to a non-Motion bridge on "
                        f"{SPLICEKIT_HOST}:{SPLICEKIT_PORT}: "
                        f"{response.get('host_bundle_id', 'unknown')}"
                    ),
                    "result": response,
                }
            else:
                ready = bool(response.get("ready", True))
                if not require_ready or ready:
                    return {
                        "status": "ok",
                        "waited_seconds": round(max(timeout_seconds - max(deadline - time.monotonic(), 0.0), 0.0), 3),
                        "require_ready": require_ready,
                        "result": response,
                    }

        if time.monotonic() >= deadline:
            break
        time.sleep(interval)

    return {
        "status": "timeout",
        "waited_seconds": round(max(timeout_seconds, 0.0), 3),
        "require_ready": require_ready,
        "last_result": last_response,
    }


def _surface() -> dict:
    return load_motion_surface(MOTION_APP_PATH)


def _surface_or_error() -> tuple[dict | None, str | None]:
    try:
        return _surface(), None
    except Exception as exc:
        return None, f"Error loading Motion command surface from {MOTION_APP_PATH}: {exc}"


def _palette_status() -> tuple[dict | None, str | None]:
    response = bridge.call("command.status")
    if _err(response):
        return None, response.get("error", "unknown bridge error")
    if "visible" not in response:
        return None, f"Unexpected palette status response: {response}"
    return response, None


def _send_palette_hotkey(delay_seconds: float = 0.75) -> tuple[dict | None, str | None]:
    try:
        bundle_id = None
        version = bridge.call("system.version")
        if not _err(version) and _is_motion_host(version):
            bundle_id = version.get("host_bundle_id")

        if bundle_id:
            subprocess.run(
                ["open", "-b", str(bundle_id)],
                check=True,
                capture_output=True,
                text=True,
            )
        else:
            subprocess.run(
                ["open", "-a", MOTION_APP_PATH],
                check=True,
                capture_output=True,
                text=True,
            )
        subprocess.run(
            [
                "osascript",
                "-e",
                f"delay {delay_seconds}",
                "-e",
                "tell application \"System Events\" to keystroke \"P\" using {command down, shift down}",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        stdout = (exc.stdout or "").strip()
        detail = stderr or stdout or str(exc)
        return None, f"Failed to send Cmd+Shift+P to Motion: {detail}"
    time.sleep(max(delay_seconds, 0.1))
    return {"status": "sent", "hotkey": "Cmd+Shift+P"}, None


def _offline_motion_match(query: str, limit: int = 5) -> tuple[dict | None, dict]:
    surface, error = _surface_or_error()
    if error:
        return None, {"status": "surface_error", "error": error}

    matches = search_motion_surface(surface, query=query, limit=max(limit, 1))
    if not matches:
        return None, {"status": "no_match", "matches": []}

    top = matches[0]
    exact_match = query.casefold() in {
        str(top.get("id", "")).casefold(),
        str(top.get("display_name", "")).casefold(),
        str(top.get("selector", "")).casefold(),
    }
    clear_winner = len(matches) == 1 or exact_match

    if not clear_winner and len(matches) > 1:
        top_score = float(top.get("score", 0.0))
        next_score = float(matches[1].get("score", 0.0))
        clear_winner = (top_score - next_score) >= 0.35

    if not clear_winner:
        return None, {"status": "ambiguous", "matches": matches}

    return top, {"status": "ok", "matches": matches}


@mcp.tool()
def bridge_status() -> str:
    """Check if MotionKit is connected to a running Motion process."""
    response = bridge.call("system.ping")
    if _err(response):
        response = bridge.call("system.version")
    if _err(response):
        return f"MotionKit NOT connected: {response.get('error', response)}"
    if not _is_motion_host(response):
        return (
            "MotionKit NOT connected: connected to a non-Motion bridge on "
            f"{SPLICEKIT_HOST}:{SPLICEKIT_PORT}: "
            f"{response.get('host_bundle_id', 'unknown')}"
        )
    return _fmt(response)


@mcp.tool()
def wait_for_bridge(
    timeout_seconds: float = 15.0,
    require_ready: bool = True,
    poll_interval: float = 0.5,
) -> str:
    """Wait until MotionKit is reachable, optionally requiring a bootstrapped Motion document context."""
    return _fmt(_wait_for_bridge(timeout_seconds, require_ready, poll_interval))


@mcp.tool()
def motion_app_info() -> str:
    """Read app metadata and document types from the installed Motion bundle."""
    surface, error = _surface_or_error()
    if error:
        return error
    return _fmt(summarize_surface(surface))


@mcp.tool()
def motion_list_command_groups() -> str:
    """List Motion command groups shipped in NSProCommandGroups.plist."""
    surface, error = _surface_or_error()
    if error:
        return error
    groups = []
    for group_name in list_group_names(surface):
        payload = surface["groups"][group_name]
        groups.append(
            {
                "name": group_name,
                "color_index": payload.get("color_index"),
                "count": payload.get("count", 0),
            }
        )
    return _fmt({"groups": groups, "count": len(groups)})


@mcp.tool()
def motion_list_commands(group: str = "", limit: int = 0) -> str:
    """List Motion commands discovered from the installed app's command plists.

    Args:
        group: Optional exact group/category name such as 'Tools' or 'Transport'
        limit: Optional result cap. Use 0 to return all matches.
    """
    surface, error = _surface_or_error()
    if error:
        return error
    commands = list_commands(surface, group=group)
    if limit > 0:
        commands = commands[:limit]
    return _fmt({"commands": commands, "count": len(commands), "group": group or None})


@mcp.tool()
def motion_search_commands(query: str, limit: int = 25) -> str:
    """Search Motion's offline command surface by command id, selector, category, or group."""
    surface, error = _surface_or_error()
    if error:
        return error
    matches = search_motion_surface(surface, query=query, limit=limit)
    return _fmt({"query": query, "matches": matches, "count": len(matches)})


@mcp.tool()
def motion_describe_command(identifier: str) -> str:
    """Describe one Motion command from the offline command surface, with optional live palette context."""
    surface, error = _surface_or_error()
    if error:
        return error

    command = find_command(surface, identifier)
    if not command:
        return _fmt({"identifier": identifier, "status": "not_found"})

    group_details = []
    for group_name in command.get("groups", []):
        payload = surface["groups"].get(group_name)
        if not payload:
            continue
        group_details.append(
            {
                "name": group_name,
                "color_index": payload.get("color_index"),
                "count": payload.get("count", 0),
            }
        )

    result = {
        "identifier": identifier,
        "command": command,
        "group_details": group_details,
    }

    palette = bridge.call("command.search", query=identifier, limit=10)
    if _err(palette):
        result["live_palette_error"] = palette.get("error", palette)
    else:
        result["live_palette_matches"] = palette.get("commands", [])

    return _fmt(result)


@mcp.tool()
def motion_search_palette_commands(query: str, limit: int = 20) -> str:
    """Search the live MotionKit command palette registry inside Motion.

    Unlike motion_search_commands(), this reflects the actual command list currently
    registered in the injected palette and returns action/type pairs that can be
    executed directly with motion_execute_command().
    """
    response = bridge.call("command.search", query=query, limit=limit)
    if _err(response):
        return f"Error: {response.get('error', response)}"
    return _fmt(response)


@mcp.tool()
def motion_execute_command(action: str, type: str = "motion_command") -> str:
    """Execute a command from the live MotionKit palette registry.

    Pass the `action` and `type` values returned by motion_search_palette_commands().
    The default type is `motion_command`, which is MotionKit's host-native command path.
    """
    response = bridge.call("command.execute", action=action, type=type)
    if _err(response):
        return f"Error: {response.get('error', response)}"
    return _fmt(response)


@mcp.tool()
def motion_run_command(query: str, limit: int = 5, type: str = "motion_command") -> str:
    """Search the live palette, then execute the best match when the result is unambiguous.

    This is a convenience wrapper around motion_search_palette_commands() plus
    motion_execute_command(). It executes immediately when there is a single
    clear top match; otherwise it returns the strongest candidates.
    """
    search = bridge.call("command.search", query=query, limit=limit)
    top = None
    source = "live_palette"
    matches = []
    live_error = None

    if _err(search):
        live_error = search.get("error", search)
    else:
        commands = search.get("commands", [])
        matches = commands
        if commands:
            candidate = commands[0]
            exact_match = query.casefold() in {
                str(candidate.get("action", "")).casefold(),
                str(candidate.get("name", "")).casefold(),
                str(candidate.get("selector", "")).casefold(),
            }
            clear_winner = len(commands) == 1 or exact_match

            if not clear_winner and len(commands) > 1:
                top_score = float(candidate.get("score", 0.0))
                next_score = float(commands[1].get("score", 0.0))
                clear_winner = (top_score - next_score) >= 0.35

            if clear_winner:
                top = candidate

    if top is None and type == "motion_command":
        offline_top, offline_state = _offline_motion_match(query, limit)
        if offline_top is None:
            payload = {
                "query": query,
                "status": offline_state["status"],
                "matches": offline_state.get("matches", []),
            }
            if live_error is not None:
                payload["live_palette_error"] = live_error
            elif matches:
                payload["live_palette_matches"] = matches
            elif _err(search):
                payload["live_palette_error"] = search.get("error", search)
            return _fmt(payload)

        top = {
            "action": offline_top["id"],
            "name": offline_top.get("display_name", offline_top["id"]),
            "selector": offline_top.get("selector"),
            "category": offline_top.get("category", ""),
            "detail": offline_top.get("detail", ""),
            "score": offline_top.get("score", 0.0),
            "type": type,
            "groups": offline_top.get("groups", []),
            "source": "offline_surface",
        }
        source = "offline_surface"
        matches = offline_state.get("matches", [])

    if top is None:
        payload = {"query": query, "status": "no_match", "matches": matches}
        if live_error is not None:
            payload["live_palette_error"] = live_error
        return _fmt(payload)

    execute = bridge.call("command.execute", action=top["action"], type=type)
    if _err(execute):
        return f"Error: {execute.get('error', execute)}"
    return _fmt(
        {
            "query": query,
            "selected": top,
            "selection_source": source,
            "matches": matches,
            "live_palette_error": live_error,
            "result": execute,
        }
    )


@mcp.tool()
def show_command_palette() -> str:
    """Show the injected MotionKit command palette window."""
    response = bridge.call("command.show")
    if _err(response):
        return f"Error: {response.get('error', response)}"
    return "Command palette opened."


@mcp.tool()
def hide_command_palette() -> str:
    """Hide the injected MotionKit command palette window."""
    response = bridge.call("command.hide")
    if _err(response):
        return f"Error: {response.get('error', response)}"
    return "Command palette closed."


@mcp.tool()
def command_palette_status() -> str:
    """Inspect the live MotionKit command palette state inside Motion."""
    status, error = _palette_status()
    if error:
        return f"Error: {error}"
    return _fmt(status)


@mcp.tool()
def press_command_palette_hotkey(delay_seconds: float = 0.75) -> str:
    """Activate Motion and press Cmd+Shift+P, returning palette visibility before and after."""
    before, error = _palette_status()
    if error:
        return f"Error: {error}"
    _, error = _send_palette_hotkey(delay_seconds=delay_seconds)
    if error:
        return f"Error: {error}"
    after, error = _palette_status()
    if error:
        return f"Error: {error}"
    fallback = None
    if bool(before.get("visible")) == bool(after.get("visible")):
        toggle = bridge.call("command.hide" if bool(before.get("visible")) else "command.show")
        if _err(toggle):
            fallback = {"status": "error", "detail": toggle.get("error", toggle)}
        else:
            after, error = _palette_status()
            if error:
                return f"Error: {error}"
            fallback = {"status": "used_bridge_toggle"}
    return _fmt(
        {
            "hotkey": "Cmd+Shift+P",
            "before_visible": bool(before.get("visible")),
            "after_visible": bool(after.get("visible")),
            "toggled": bool(before.get("visible")) != bool(after.get("visible")),
            "before": before,
            "after": after,
            "fallback": fallback,
        }
    )


@mcp.tool()
def get_classes(filter: str = "") -> str:
    """List ObjC classes loaded in Motion's process.

    Common prefixes worth exploring in Motion: MG, OZ, LK, NS, CA.
    """
    response = bridge.call("system.getClasses", filter=filter) if filter else bridge.call("system.getClasses")
    if _err(response):
        return f"Error: {response.get('error', response)}"
    classes = response.get("classes", [])
    count = response.get("count", len(classes))
    if count > 200:
        return f"Found {count} classes matching '{filter}'. Showing first 200:\n" + "\n".join(classes[:200])
    return f"Found {count} classes:\n" + "\n".join(classes)


@mcp.tool()
def get_methods(class_name: str, include_super: bool = False) -> str:
    """List all methods on an ObjC class with type encodings."""
    response = bridge.call("system.getMethods", className=class_name, includeSuper=include_super)
    if _err(response):
        return f"Error: {response.get('error', response)}"
    lines = [f"=== {class_name} ==="]
    lines.append(f"\nInstance methods ({response.get('instanceMethodCount', 0)}):")
    for name in sorted(response.get("instanceMethods", {}).keys()):
        info = response["instanceMethods"][name]
        lines.append(f"  - {name}  ({info.get('typeEncoding', '')})")
    lines.append(f"\nClass methods ({response.get('classMethodCount', 0)}):")
    for name in sorted(response.get("classMethods", {}).keys()):
        info = response["classMethods"][name]
        lines.append(f"  + {name}  ({info.get('typeEncoding', '')})")
    return "\n".join(lines)


@mcp.tool()
def get_properties(class_name: str) -> str:
    """List declared @property definitions on an ObjC class."""
    response = bridge.call("system.getProperties", className=class_name)
    if _err(response):
        return f"Error: {response.get('error', response)}"
    lines = [f"{class_name}: {response.get('count', 0)} properties"]
    for prop in response.get("properties", []):
        lines.append(f"  {prop['name']}: {prop['attributes']}")
    return "\n".join(lines)


@mcp.tool()
def get_ivars(class_name: str) -> str:
    """List instance variables of an ObjC class with their types."""
    response = bridge.call("system.getIvars", className=class_name)
    if _err(response):
        return f"Error: {response.get('error', response)}"
    lines = [f"{class_name}: {response.get('count', 0)} ivars"]
    for ivar in response.get("ivars", []):
        lines.append(f"  {ivar['name']}: {ivar['type']}")
    return "\n".join(lines)


@mcp.tool()
def get_protocols(class_name: str) -> str:
    """List protocols adopted by an ObjC class."""
    response = bridge.call("system.getProtocols", className=class_name)
    if _err(response):
        return f"Error: {response.get('error', response)}"
    return f"{class_name}: {response.get('count', 0)} protocols\n" + "\n".join(
        f"  {protocol}" for protocol in response.get("protocols", [])
    )


@mcp.tool()
def get_superchain(class_name: str) -> str:
    """Get the inheritance chain for an ObjC class."""
    response = bridge.call("system.getSuperchain", className=class_name)
    if _err(response):
        return f"Error: {response.get('error', response)}"
    return " -> ".join(response.get("superchain", []))


@mcp.tool()
def explore_class(class_name: str) -> str:
    """Comprehensive overview of an ObjC class: inheritance, protocols, properties, ivars, key methods."""
    lines = [f"=== {class_name} ===\n"]

    response = bridge.call("system.getSuperchain", className=class_name)
    if not _err(response):
        lines.append("Inheritance: " + " -> ".join(response.get("superchain", [])))

    response = bridge.call("system.getProtocols", className=class_name)
    if not _err(response) and response.get("count", 0) > 0:
        lines.append(f"\nProtocols ({response['count']}): " + ", ".join(response.get("protocols", [])))

    response = bridge.call("system.getProperties", className=class_name)
    if not _err(response) and response.get("count", 0) > 0:
        lines.append(f"\nProperties ({response['count']}):")
        for prop in response.get("properties", [])[:30]:
            lines.append(f"  {prop['name']}")

    response = bridge.call("system.getIvars", className=class_name)
    if not _err(response) and response.get("count", 0) > 0:
        lines.append(f"\nIvars ({response['count']}):")
        for ivar in response.get("ivars", [])[:15]:
            lines.append(f"  {ivar['name']}: {ivar['type']}")

    response = bridge.call("system.getMethods", className=class_name)
    if not _err(response):
        instance_count = response.get("instanceMethodCount", 0)
        class_count = response.get("classMethodCount", 0)
        lines.append(f"\nMethods: {instance_count} instance, {class_count} class")
        keywords = [
            "get",
            "set",
            "current",
            "active",
            "selected",
            "add",
            "remove",
            "create",
            "delete",
            "open",
            "close",
            "command",
            "window",
            "document",
            "canvas",
            "tool",
            "play",
            "marker",
        ]
        notable = [
            method_name
            for method_name in sorted(response.get("instanceMethods", {}).keys())
            if any(keyword in method_name.lower() for keyword in keywords)
        ]
        if notable:
            lines.append(f"\nNotable instance methods ({len(notable)} of {instance_count}):")
            for method_name in notable[:50]:
                lines.append(f"  - {method_name}")
    return "\n".join(lines)


@mcp.tool()
def search_methods(class_name: str, keyword: str) -> str:
    """Search for methods on a class by keyword."""
    response = bridge.call("system.getMethods", className=class_name)
    if _err(response):
        return f"Error: {response.get('error', response)}"
    lines = []
    for name in sorted(response.get("instanceMethods", {}).keys()):
        if keyword.lower() in name.lower():
            lines.append(f"  - {name}  ({response['instanceMethods'][name].get('typeEncoding', '')})")
    for name in sorted(response.get("classMethods", {}).keys()):
        if keyword.lower() in name.lower():
            lines.append(f"  + {name}  ({response['classMethods'][name].get('typeEncoding', '')})")
    if not lines:
        return f"No methods matching '{keyword}' on {class_name}"
    return f"Methods matching '{keyword}' on {class_name} ({len(lines)}):\n" + "\n".join(lines)


@mcp.tool()
def call_method(class_name: str, selector: str, class_method: bool = True) -> str:
    """Call a zero-argument ObjC method."""
    return _call_or_error("system.callMethod", className=class_name, selector=selector, classMethod=class_method)


@mcp.tool()
def call_method_with_args(
    target: str,
    selector: str,
    args: str | list = "[]",
    class_method: bool = True,
    return_handle: bool = False,
) -> str:
    """Call any ObjC method with typed arguments via NSInvocation."""
    if isinstance(args, list):
        parsed_args = args
    else:
        try:
            parsed_args = json.loads(args)
        except json.JSONDecodeError as exc:
            return f"Invalid args JSON: {exc}"

    return _call_or_error(
        "system.callMethodWithArgs",
        target=target,
        selector=selector,
        args=parsed_args,
        classMethod=class_method,
        returnHandle=return_handle,
    )


@mcp.tool()
def manage_handles(action: str = "list", handle: str = "") -> str:
    """Manage object handles stored by MotionKit."""
    if action == "list":
        response = bridge.call("object.list")
    elif action == "inspect" and handle:
        response = bridge.call("object.get", handle=handle)
    elif action == "release" and handle:
        response = bridge.call("object.release", handle=handle)
    elif action == "release_all":
        response = bridge.call("object.release", all=True)
    else:
        return "Usage: manage_handles(action='list|inspect|release|release_all', handle='obj_N')"

    if _err(response):
        return f"Error: {response.get('error', response)}"
    return _fmt(response)


@mcp.tool()
def get_object_property(handle: str, key: str, return_handle: bool = False) -> str:
    """Read a property from an object handle using Key-Value Coding."""
    return _call_or_error("object.getProperty", handle=handle, key=key, returnHandle=return_handle)


@mcp.tool()
def set_object_property(handle: str, key: str, value: str, value_type: str = "string") -> str:
    """Set a property on an object handle using Key-Value Coding."""
    value_spec = {"type": value_type, "value": value}
    if value_type == "int":
        value_spec["value"] = int(value)
    elif value_type == "double":
        value_spec["value"] = float(value)
    elif value_type == "bool":
        value_spec["value"] = value.lower() in ("true", "1", "yes")
    return _call_or_error("object.setProperty", handle=handle, key=key, value=value_spec)


@mcp.tool()
def execute_menu_command(menu_path: list[str]) -> str:
    """Execute any Motion menu command by walking the menu hierarchy."""
    return _call_or_error("menu.execute", menuPath=menu_path)


@mcp.tool()
def list_menus(menu: str = "", depth: int = 2) -> str:
    """List menu items from Motion's menu bar."""
    params = {"depth": depth}
    if menu:
        params["menu"] = menu
    return _call_or_error("menu.list", **params)


@mcp.tool()
def detect_dialog() -> str:
    """Detect any visible dialog, sheet, alert, or popup in Motion."""
    return _call_or_error("dialog.detect")


@mcp.tool()
def click_dialog_button(button: str = "", index: int = -1) -> str:
    """Click a button in the currently showing dialog."""
    params = {}
    if button:
        params["button"] = button
    if index >= 0:
        params["index"] = index
    return _call_or_error("dialog.click", **params)


@mcp.tool()
def fill_dialog_field(value: str, index: int = 0) -> str:
    """Fill a text field in the currently showing dialog."""
    return _call_or_error("dialog.fill", value=value, index=index)


@mcp.tool()
def toggle_dialog_checkbox(checkbox: str, checked: bool | None = None) -> str:
    """Toggle or set a checkbox in the currently showing dialog."""
    params = {"checkbox": checkbox}
    if checked is not None:
        params["checked"] = checked
    return _call_or_error("dialog.checkbox", **params)


@mcp.tool()
def select_dialog_popup(select: str, popup_index: int = 0) -> str:
    """Select an item from a popup menu in the currently showing dialog."""
    return _call_or_error("dialog.popup", select=select, popupIndex=popup_index)


@mcp.tool()
def dismiss_dialog(action: str = "default") -> str:
    """Dismiss the currently showing dialog."""
    return _call_or_error("dialog.dismiss", action=action)


@mcp.tool()
def raw_call(method: str, params: str = "{}") -> str:
    """Send a raw JSON-RPC call to MotionKit. Last resort when no other tool fits."""
    try:
        parsed_params = json.loads(params)
    except json.JSONDecodeError as exc:
        return f"Invalid params JSON: {exc}"
    response = bridge.call(method, parsed_params)
    if _err(response):
        return f"Error: {response.get('error', response)}"
    return _fmt(response)


if __name__ == "__main__":
    mcp.run(transport="stdio")
