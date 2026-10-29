"""Opt-in protocol tests for the packaged server, without a tunnel or API key."""
import asyncio
import json
import os
import select
import subprocess
import time
import uuid
from pathlib import Path

import pytest
from fastmcp import Client
from fastmcp.client.transports import StdioTransport


@pytest.mark.skipif(not os.environ.get("PROJECT_MCP_FROZEN_SERVER"), reason="frozen runtime not requested")
def test_frozen_server_contract(tmp_path):
    executable = Path(os.environ["PROJECT_MCP_FROZEN_SERVER"]).resolve()
    assert executable.is_file(), "build the frozen server first"
    project = tmp_path / "项目 with spaces,comma"
    project.mkdir()
    (project / "README.md").write_text("hello\nneedle\n", encoding="utf-8")
    (project / "linked.md").symlink_to(tmp_path / "outside.md")
    (tmp_path / "outside.md").write_text("private", encoding="utf-8")
    for i in range(205):
        (project / f"{i:03}.txt").touch()

    async def check():
        transport = StdioTransport(command=str(executable), args=[], cwd=str(executable.parent), env={"PROJECT_ROOT": str(project)})
        async with Client(transport, timeout=20) as client:
            assert {t.name for t in await client.list_tools()} == {"list_files", "read_file", "search_files"}
            first = await client.call_tool("list_files", {"recursive": True})
            assert len(first.structured_content["files"]) == 200
            second = await client.call_tool("list_files", {"recursive": True, "cursor": first.structured_content["next_cursor"]})
            assert second.structured_content["next_cursor"] is None
            read = await client.call_tool("read_file", {"path": "README.md", "max_lines": 1})
            assert read.structured_content["content"] == "hello\n"
            follow = await client.call_tool("read_file", {"path": "README.md", "start_line": read.structured_content["next_line"], "start_column": read.structured_content["next_column"]})
            assert follow.structured_content["content"] == "needle\n"
            for path in ("../outside.md", "linked.md"):
                result = await client.call_tool("read_file", {"path": path})
                assert "error" in result.structured_content
            matches = await client.call_tool("search_files", {"query": "needle"})
            assert matches.structured_content["matches"][0]["line_number"] == 2
            wire = {"content": [c.model_dump(mode="json") for c in first.content], "structuredContent": first.structured_content}
            assert len(json.dumps(wire).encode()) < 10 * 1024 * 1024

    asyncio.run(check())


@pytest.mark.skipif(not os.environ.get("PROJECT_MCP_APP_BUNDLE"), reason="app bundle not requested")
def test_packaged_native_preflight_without_credentials(tmp_path):
    app = Path(os.environ["PROJECT_MCP_APP_BUNDLE"]).resolve()
    helper = app / "Contents/MacOS/ProjectMCPSupervisor"
    resources = app / "Contents/Resources"
    assert helper.is_file()
    frame = {
        "id": str(uuid.uuid4()), "mode": "preflight",
        "runtimeURL": (resources / "runtime/tunnel-client").as_uri(),
        "serverDirectoryURL": (resources / "server").as_uri(),
        "projectPath": str(tmp_path), "tunnelID": "tunnel_test", "organizationID": "org-test",
        "healthURLFile": (tmp_path / "health").as_uri(),
    }
    process = subprocess.Popen([str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env={"PATH": "/usr/bin:/bin", "HOME": str(tmp_path), "TMPDIR": str(tmp_path)})
    events = []
    try:
        process.stdin.write(json.dumps(frame).encode() + b"\n")
        process.stdin.flush()
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            readable, _, _ = select.select([process.stdout], [], [], 1)
            if readable:
                line = process.stdout.readline()
                if not line:
                    break
                events.append(json.loads(line))
        assert process.wait(timeout=7) == 0, events
        assert any(event["kind"] == "preflightPassed" for event in events), events
        assert not any(event["kind"] == "failure" for event in events), events
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=7)
