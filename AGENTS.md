# Project MCP

Minimal Python + FastMCP 2.x STDIO server for read-only access to one local project.

## Run and verify

- Python 3.10+; install `requirements.txt` in a virtual environment.
- Export `PROJECT_ROOT`, then run `python server.py`.
- Run `python -m pytest -q` before committing changes.
- Desktop core: `swift test --package-path desktop/macos`.
- Test app bundle: `bash scripts/build-macos.sh --test-package`; see docs/macos-app.md.
- See README.md for Secure MCP Tunnel setup and pagination examples.

## Structure and conventions

- `server.py`: configuration, ProjectReader, and exactly three registered tools.
- `tests/test_server.py`: real temporary filesystem tests; no external services needed.
- `README.md`: authoritative user-facing setup, tool contract, and limitations.
- `.env.example`: generic configuration only; `.env` remains local.
- `desktop/macos/`: SwiftUI launcher, process supervisor, credential/logging core.
- `packaging/macos/`, `scripts/`: isolated build recipes; generated binaries stay ignored.
- Keep tools read-only: no subprocess, shell execution, writes, deletes, or moves.
- Preserve root containment and symlink rejection when changing file access.
- Keep paged responses within 512 KiB of conservatively serialized tool JSON.
- Never commit credentials, personal project contents, or downloaded tunnel binaries.

## Current state

Directory/search pagination, long-line continuation, and response limits are implemented.
This Git repository is the maintained source; older local copies may still be used by
existing tunnel processes. Do not delete or stop them as part of routine cleanup.
Changes take effect after restarting the tunnel against this repository's server.py.
No database, embeddings, web UI, or write-capable tools are planned by default.
The native launcher may store its own settings and manage only processes it owns;
these desktop functions must never be exposed as MCP tools. UI remains frosted,
minimal, with configuration/logs in settings and no explanatory secondary copy.
