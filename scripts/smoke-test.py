#!/usr/bin/env python3
"""Starts a codenav-swift-mcp binary, speaks MCP over stdio and checks the handshake and tool list.

Usage: smoke-test.py /path/to/codenav-swift-mcp [workspace]
"""
import json
import os
import subprocess
import sys

binary = sys.argv[1]
workspace = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.getcwd()
env = dict(os.environ, CODENAV_SWIFT_WORKSPACE=workspace)
process = subprocess.Popen(
    [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, text=True
)


def request(message):
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()
    return json.loads(process.stdout.readline())


init = request({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke-test", "version": "0"}},
})
print("server:", init["result"]["serverInfo"])
process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
tools = request({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})["result"]["tools"]
names = sorted(tool["name"] for tool in tools)
print("tools:", ", ".join(names))
process.terminate()
if len(names) != 11 or "symbol_info" not in names:
    sys.exit(f"expected 11 tools including symbol_info, got {len(names)}")
print("smoke test passed")
