#!/usr/bin/env python3
"""Launch-time and runtime smoke test for the MotionKit host bridge."""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path


HOST = "127.0.0.1"
PORT = int(os.environ.get("MOTIONKIT_PORT", "9878"))
REPO_ROOT = Path(__file__).resolve().parents[1]


class BridgeClient:
    def __init__(self, host: str = HOST, port: int = PORT) -> None:
        self.host = host
        self.port = port
        self.sock: socket.socket | None = None
        self.buf = b""
        self.request_id = 0

    def connect(self) -> None:
        if self.sock is not None:
            return
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(30)
        sock.connect((self.host, self.port))
        self.sock = sock
        self.buf = b""

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            finally:
                self.sock = None
                self.buf = b""

    def call(self, method: str, **params) -> dict:
        self.request_id += 1
        request = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": self.request_id,
        }
        self.connect()
        assert self.sock is not None
        self.sock.sendall(json.dumps(request).encode("utf-8") + b"\n")
        while b"\n" not in self.buf:
            chunk = self.sock.recv(16 * 1024 * 1024)
            if not chunk:
                self.close()
                raise ConnectionError("bridge closed connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        response = json.loads(line)
        if "error" in response:
            raise RuntimeError(response["error"])
        return response.get("result", {})


def launch_motion() -> None:
    subprocess.run(
        ["make", "launch"],
        cwd=REPO_ROOT,
        check=True,
    )


def bootstrap_motion_document_context(client: BridgeClient) -> dict:
    return client.call(
        "system.callMethod",
        className="SpliceKitCommandPalette",
        classMethod=True,
        selector="bootstrapMotionDocumentContextIfNeeded",
    )


def wait_until_ready(client: BridgeClient, timeout_seconds: float, interval_seconds: float) -> dict:
    deadline = time.monotonic() + timeout_seconds
    last_error: str | None = None
    bootstrap_attempted = False
    while time.monotonic() < deadline:
        try:
            result = client.call("system.ping")
            if result.get("ready"):
                return result
            if (
                not bootstrap_attempted
                and result.get("motion_host")
                and not result.get("ready")
                and result.get("document_count", 0) == 0
            ):
                bootstrap_attempted = True
                bootstrap_motion_document_context(client)
            last_error = f"bridge reachable but not ready: {json.dumps(result, default=str)}"
        except Exception as exc:  # noqa: BLE001
            last_error = str(exc)
            client.close()
        time.sleep(interval_seconds)
    raise TimeoutError(last_error or "timed out waiting for ready bridge")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=float, default=90.0, help="Hold duration after startup")
    parser.add_argument("--interval", type=float, default=10.0, help="Ping interval during hold")
    parser.add_argument(
        "--ready-timeout",
        type=float,
        default=45.0,
        help="Max seconds to wait for system.ping ready=1",
    )
    parser.add_argument(
        "--query",
        default="text tool",
        help="Optional command.search query to verify after startup",
    )
    parser.add_argument(
        "--skip-launch",
        action="store_true",
        help="Assume Motion is already running and skip make launch",
    )
    args = parser.parse_args()

    client = BridgeClient()
    try:
        if not args.skip_launch:
            launch_motion()

        ready = wait_until_ready(client, args.ready_timeout, min(args.interval, 1.0))
        print("READY", json.dumps(ready, indent=2, default=str))

        if args.query:
            search = client.call("command.search", query=args.query, limit=5)
            print("SEARCH", json.dumps(search, indent=2, default=str))

        steps = max(int(args.duration // args.interval), 1)
        for index in range(steps):
            time.sleep(args.interval)
            result = client.call("system.ping")
            print(f"PING_{index + 1}", json.dumps(result, indent=2, default=str))
            if not result.get("ready"):
                print("Bridge dropped readiness during hold window", file=sys.stderr)
                return 1

        print("Smoke test passed.")
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
