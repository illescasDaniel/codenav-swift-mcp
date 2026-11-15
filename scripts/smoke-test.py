#!/usr/bin/env python3
"""Starts a codenav-swift-mcp binary, speaks MCP over stdio and checks the handshake and tool list.

Usage: smoke-test.py /path/to/codenav-swift-mcp [workspace]
"""
import json
import os
import subprocess
import sys

binary = os.path.abspath(sys.argv[1])
workspace = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.getcwd()
env = dict(os.environ)
# Exercise workspace selection without a pin so an unexpected roots/list request fails the test.
env.pop("CODENAV_SWIFT_WORKSPACE", None)


def smoke_test(protocol, capabilities, client_info):
    with subprocess.Popen(
        [binary], cwd=workspace, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, env=env, text=True,
    ) as process:
        def send(message):
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()

        def request(request_id, method, params=None):
            message = {"jsonrpc": "2.0", "id": request_id, "method": method}
            if params is not None:
                message["params"] = params
            send(message)
            reply = json.loads(process.stdout.readline())
            if reply.get("id") != request_id or "result" not in reply:
                raise AssertionError(f"{method}: expected a result, got {reply}")
            return reply["result"]

        try:
            init = request(1, "initialize", {
                "protocolVersion": protocol,
                "capabilities": capabilities,
                "clientInfo": client_info,
            })
            assert init["protocolVersion"] == protocol, init
            print("server:", init["serverInfo"], "for", client_info["name"])
            send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            tools = request(2, "tools/list")["tools"]
            names = sorted(tool["name"] for tool in tools)
            assert names == expected, names
            # Neither client advertises roots. A tool that selects a workspace must still answer.
            result = request(3, "tools/call", {"name": "workspace", "arguments": {}})
            assert not result.get("isError"), result
        finally:
            process.terminate()


# The read-only tools; the editing tools are listed only with CODENAV_SWIFT_WRITE=1.
expected = sorted([
    "affected_tests", "callers", "definition", "diagnostics", "hover", "implementations", "outline",
    "references", "search_symbol", "symbol_info", "type_at", "verify", "workspace",
])
smoke_test("2025-03-26", {}, {"name": "smoke-test", "version": "0"})
smoke_test(
    "2025-06-18",
    {"experimental": {"codex/auth-change": {}}, "elicitation": {"form": {}, "url": {}}},
    {"name": "codex-mcp-client", "title": "Codex", "version": "0.169.0"},
)
print("smoke test passed")
