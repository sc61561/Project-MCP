"""A minimal, read-only MCP server for inspecting one local project directory."""

from __future__ import annotations

import os
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from fastmcp import FastMCP


PROJECT_ROOT_ENV = "PROJECT_ROOT"
MAX_READ_BYTES_ENV = "MAX_READ_BYTES"
DEFAULT_MAX_READ_BYTES = 1024 * 1024
MAX_SEARCH_RESULTS = 200
MAX_RESPONSE_BYTES = 512 * 1024
MAX_CONTENT_CHARS = 32768
MAX_SNIPPET_CHARS = 200

TEXT_EXTENSIONS = {
    ".md",
    ".txt",
    ".json",
    ".yaml",
    ".yml",
    ".py",
    ".js",
    ".jsx",
    ".ts",
    ".tsx",
    ".dart",
    ".toml",
    ".ini",
    ".cfg",
    ".conf",
    ".html",
    ".css",
    ".scss",
    ".sql",
    ".sh",
    ".xml",
    ".csv",
    ".graphql",
    ".gql",
    ".go",
    ".rs",
    ".java",
    ".kt",
    ".kts",
    ".c",
    ".h",
    ".cc",
    ".cpp",
    ".cxx",
    ".swift",
    ".rb",
    ".php",
    ".vue",
    ".svelte",
}

IGNORED_DIRECTORIES = {
    ".git",
    "node_modules",
    "build",
    "dist",
    ".next",
    ".venv",
    "venv",
    "__pycache__",
    "coverage",
    "out",
}


def load_project_root() -> Path:
    """Load and validate the configured project root."""

    raw_root = os.environ.get(PROJECT_ROOT_ENV)
    if not raw_root:
        raise RuntimeError("PROJECT_ROOT must be set to an existing directory")

    try:
        root = Path(raw_root).expanduser().resolve(strict=True)
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"PROJECT_ROOT cannot be resolved: {exc}") from exc

    if not root.is_dir():
        raise RuntimeError(f"PROJECT_ROOT is not a directory: {root}")
    return root


def load_max_read_bytes() -> int:
    raw_limit = os.environ.get(MAX_READ_BYTES_ENV)
    if raw_limit is None:
        return DEFAULT_MAX_READ_BYTES

    try:
        limit = int(raw_limit)
    except ValueError as exc:
        raise RuntimeError("MAX_READ_BYTES must be a positive integer") from exc
    if limit <= 0:
        raise RuntimeError("MAX_READ_BYTES must be a positive integer")
    return limit


def _relative_path(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def _without_line_ending(line: str) -> str:
    return line.rstrip("\r\n")


def _json_size(value: object) -> int:
    # ASCII escaping is conservative, including control characters and emoji.
    return len(json.dumps(value, ensure_ascii=True).encode("utf-8"))


def _page_offset(cursor: str | None) -> int:
    if cursor is None:
        return 0
    if not isinstance(cursor, str) or not cursor.isascii() or not cursor.isdigit() or len(cursor) > 12:
        raise ValueError("cursor must be a non-negative numeric next_cursor from the previous page")
    return int(cursor)


def _validate_limit(limit: int, maximum: int) -> None:
    if type(limit) is not int or not 1 <= limit <= maximum:
        raise ValueError(f"limit must be between 1 and {maximum}")


def _paginate(items, key: str, metadata: dict, limit: int, cursor: str | None):
    offset = _page_offset(cursor)
    page = []
    size = _json_size(metadata) + 1024
    next_cursor = None
    for index, item in enumerate(items):
        if index < offset:
            continue
        item_size = _json_size(item) + 2
        if len(page) >= limit or size + item_size > MAX_RESPONSE_BYTES:
            next_cursor = str(index)
            break
        page.append(item)
        size += item_size
    return {**metadata, key: page, "truncated": next_cursor is not None, "next_cursor": next_cursor}


def _excerpt(line: str, needle: str | None = None) -> str:
    text = _without_line_ending(line)
    position = text.casefold().find(needle) if needle else 0
    # Convert a casefold index back to an original character index when necessary.
    if needle and position >= 0 and len(text.casefold()) != len(text):
        folded_index = 0
        for i, char in enumerate(text):
            if folded_index >= position:
                position = i
                break
            folded_index += len(char.casefold())
    start = max(0, position - 50)
    end = min(len(text), start + max(MAX_SNIPPET_CHARS, len(needle or "") + 100))
    return ("…" if start else "") + text[start:end] + ("…" if end < len(text) else "")


class ProjectReader:
    """Read-only access to files below one real project root."""

    def __init__(self, root: Path, max_read_bytes: int = DEFAULT_MAX_READ_BYTES):
        self.root = root.resolve(strict=True)
        if not self.root.is_dir():
            raise RuntimeError(f"PROJECT_ROOT is not a directory: {self.root}")
        if max_read_bytes <= 0:
            raise ValueError("max_read_bytes must be a positive integer")
        self.max_read_bytes = min(max_read_bytes, DEFAULT_MAX_READ_BYTES)

    def _resolve_path(self, path: str, *, must_exist: bool = True) -> Path:
        if not isinstance(path, str):
            raise ValueError("path must be a relative string")
        if "\x00" in path:
            raise ValueError("path contains a NUL byte")
        if len(path) > 4096:
            raise ValueError("path must not exceed 4096 characters")

        candidate_input = Path(path)
        if candidate_input.is_absolute():
            raise ValueError("path must be relative to PROJECT_ROOT")

        lexical_candidate = self.root / candidate_input
        candidate = lexical_candidate.resolve(strict=False)
        if candidate != self.root and self.root not in candidate.parents:
            raise ValueError("path resolves outside PROJECT_ROOT")

        if must_exist and not candidate.exists():
            raise FileNotFoundError(f"path does not exist: {path}")

        current = self.root
        for part in candidate_input.parts:
            if part in ("", "."):
                continue
            current = current / part
            if current.is_symlink():
                raise ValueError("symbolic links are not supported")

        return candidate

    def _entry_info(self, path: Path) -> dict[str, object]:
        stat = path.stat(follow_symlinks=False)
        if path.is_dir():
            entry_type = "directory"
        elif path.is_file():
            entry_type = "file"
        else:
            entry_type = "other"

        return {
            "name": path.name,
            "relative_path": _relative_path(self.root, path),
            "type": entry_type,
            "size_bytes": stat.st_size,
            "modified_time": datetime.fromtimestamp(
                stat.st_mtime, tz=timezone.utc
            ).isoformat(),
        }

    def _iter_directory_entries(self, base: Path, recursive: bool):
        if not recursive:
            for path in sorted(base.iterdir(), key=lambda item: item.name):
                if not path.is_symlink():
                    yield path
            return

        for current, directories, files in os.walk(
            base, topdown=True, followlinks=False
        ):
            current_path = Path(current)
            directories[:] = sorted(
                name
                for name in directories
                if name not in IGNORED_DIRECTORIES
                and not (current_path / name).is_symlink()
            )
            for name in sorted(directories):
                yield current_path / name
            for name in sorted(files):
                path = current_path / name
                if not path.is_symlink():
                    yield path

    def list_files(self, path: str = "", recursive: bool = False,
                   limit: int = 200, cursor: str | None = None) -> dict[str, object]:
        try:
            _validate_limit(limit, 500)
            _page_offset(cursor)
            base = self._resolve_path(path)
            if not base.is_dir():
                raise NotADirectoryError(f"path is not a directory: {path or '.'}")

            metadata = {
                "path": _relative_path(self.root, base) if base != self.root else ".",
                "recursive": recursive,
            }
            entries = (self._entry_info(item) for item in self._iter_directory_entries(base, recursive))
            return _paginate(entries, "files", metadata, limit, cursor)
        except (FileNotFoundError, NotADirectoryError, OSError, ValueError) as exc:
            return {"error": str(exc)}

    def _ensure_text_file(self, path: str) -> Path:
        candidate = self._resolve_path(path)
        if not candidate.is_file():
            raise ValueError(f"path is not a file: {path}")
        if candidate.suffix.lower() not in TEXT_EXTENSIONS:
            raise ValueError(f"only allowlisted text files are supported: {path}")
        return candidate

    def read_file(self, path: str, start_line: int = 1, max_lines: int = 200,
                  start_column: int = 0) -> dict[str, object]:
        try:
            if type(start_line) is not int or start_line < 1:
                raise ValueError("start_line must be a positive integer (1-based)")
            if type(start_column) is not int or start_column < 0:
                raise ValueError("start_column must be a non-negative character offset")
            _validate_limit(max_lines, 1000)
            candidate = self._ensure_text_file(path)
            size_bytes = candidate.stat().st_size
            if size_bytes > self.max_read_bytes:
                raise ValueError(
                    f"file exceeds maximum read size of {self.max_read_bytes} bytes: {path}"
                )

            with candidate.open("rb") as handle:
                content_bytes = handle.read(self.max_read_bytes + 1)
            if len(content_bytes) > self.max_read_bytes:
                raise ValueError(
                    f"file exceeds maximum read size of {self.max_read_bytes} bytes: {path}"
                )

            try:
                content = content_bytes.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise ValueError(f"file is not valid UTF-8 text: {path}") from exc

            lines = content.splitlines(keepends=True)
            if start_line > len(lines) + 1:
                raise ValueError("start_line is past end of file")
            index = start_line - 1
            if start_column and (index >= len(lines) or start_column >= len(lines[index])):
                raise ValueError("start_column is past end of line")
            column = start_column
            pieces = []
            remaining = MAX_CONTENT_CHARS
            end_index = min(len(lines), index + max_lines)
            while index < end_index and remaining:
                piece = lines[index][column:column + remaining]
                pieces.append(piece)
                remaining -= len(piece)
                column += len(piece)
                if column == len(lines[index]):
                    index += 1
                    column = 0
            truncated = index < len(lines)
            return {
                "path": _relative_path(self.root, candidate),
                "size_bytes": len(content_bytes),
                "content": "".join(pieces),
                "start_line": start_line,
                "start_column": start_column,
                "truncated": truncated,
                "next_line": index + 1 if truncated else None,
                "next_column": column if truncated else None,
            }
        except (FileNotFoundError, OSError, ValueError) as exc:
            return {"error": str(exc)}

    def _iter_search_files(self):
        for current, directories, files in os.walk(
            self.root, topdown=True, followlinks=False
        ):
            current_path = Path(current)
            directories[:] = sorted(
                name
                for name in directories
                if name not in IGNORED_DIRECTORIES
                and not (current_path / name).is_symlink()
            )
            for name in sorted(files):
                path = current_path / name
                if path.is_symlink() or path.suffix.lower() not in TEXT_EXTENSIONS:
                    continue
                yield path

    def search_files(self, query: str, limit: int = 200,
                     cursor: str | None = None) -> dict[str, object]:
        try:
            if not isinstance(query, str) or not query.strip():
                raise ValueError("query must not be empty")
            if len(query) > 512:
                raise ValueError("query must not exceed 512 characters")
            _validate_limit(limit, MAX_SEARCH_RESULTS)
            _page_offset(cursor)

            needle = query.casefold()
            metadata = {"query": query, "skipped_files": 0,
                        "max_file_bytes": self.max_read_bytes}

            def matches():
                for path in self._iter_search_files():
                    try:
                        # Revalidate the path before opening, retaining the root/symlink checks.
                        candidate = self._ensure_text_file(_relative_path(self.root, path))
                        if candidate.stat().st_size > self.max_read_bytes:
                            metadata["skipped_files"] += 1
                            continue
                        with candidate.open("rb") as handle:
                            raw = handle.read(self.max_read_bytes + 1)
                        if len(raw) > self.max_read_bytes:
                            metadata["skipped_files"] += 1
                            continue
                        lines = raw.decode("utf-8").splitlines()
                        for i, line in enumerate(lines):
                            if needle not in line.casefold():
                                continue
                            before = [_excerpt(lines[i - 1])] if i else []
                            after = [_excerpt(lines[i + 1])] if i + 1 < len(lines) else []
                            excerpt = _excerpt(line, needle)
                            yield {"path": _relative_path(self.root, candidate),
                                   "line_number": i + 1, "line": excerpt,
                                   "line_truncated": excerpt != line,
                                   "context_before": before, "context_after": after,
                                   "context_truncated": any(len(s) > MAX_SNIPPET_CHARS for s in lines[max(0, i - 1):i + 2])}
                    except (OSError, UnicodeDecodeError, ValueError):
                        metadata["skipped_files"] += 1

            return _paginate(matches(), "matches", metadata, limit, cursor)
        except (OSError, ValueError) as exc:
            return {"error": str(exc)}

def _build_reader() -> ProjectReader:
    try:
        return ProjectReader(load_project_root(), max_read_bytes=load_max_read_bytes())
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"PROJECT_ROOT cannot be used: {exc}") from exc


try:
    reader: ProjectReader | None = _build_reader()
    startup_error: str | None = None
except RuntimeError as exc:
    reader = None
    startup_error = str(exc)


def _safe_call(operation: Callable[[], dict[str, object]]) -> dict[str, object]:
    if reader is None:
        return {"error": f"server is not configured: {startup_error}"}
    try:
        result = operation()
        if _json_size(result) > MAX_RESPONSE_BYTES:
            return {"error": "response exceeds 512 KiB; use a smaller page or narrower path/query"}
        return result
    except (FileNotFoundError, OSError, ValueError, RuntimeError) as exc:
        return {"error": str(exc)}


mcp = FastMCP("Read-only Local Project")


@mcp.tool
def list_files(path: str = "", recursive: bool = False, limit: int = 200,
               cursor: str | None = None) -> dict[str, object]:
    """List one page below PROJECT_ROOT; recursive traversal skips vendor/build directories.

    Pass next_cursor back with the same path/recursive to continue. Default 200, max 500.
    Restart pagination if project files change between calls.
    """

    return _safe_call(lambda: reader.list_files(path, recursive, limit, cursor))  # type: ignore[union-attr]


@mcp.tool
def read_file(path: str, start_line: int = 1, max_lines: int = 200,
              start_column: int = 0) -> dict[str, object]:
    """Read a UTF-8 text page, default 200 lines (max 1000), at most 32768 characters.

    If truncated, continue using BOTH next_line and next_column as start_line/start_column.
    Line numbers are 1-based; column is a 0-based Unicode character offset, not bytes.
    Files above MAX_READ_BYTES (at most 1 MiB) are rejected. Restart if file changes.
    """

    return _safe_call(lambda: reader.read_file(path, start_line, max_lines, start_column))  # type: ignore[union-attr]


@mcp.tool
def search_files(query: str, limit: int = 200,
                 cursor: str | None = None) -> dict[str, object]:
    """Search UTF-8 files, returning at most 200 short matches per page.

    Continue with next_cursor and the same query. Long lines/context are excerpted.
    Files above max_file_bytes are skipped; skipped_files counts skips during this scan.
    Restart pagination if project files change between calls.
    """

    return _safe_call(lambda: reader.search_files(query, limit, cursor))  # type: ignore[union-attr]


if __name__ == "__main__":
    if startup_error:
        raise SystemExit(startup_error)
    mcp.run()
