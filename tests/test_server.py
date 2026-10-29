import importlib
import json
import sys
from pathlib import Path

import pytest


@pytest.fixture
def project_root(tmp_path: Path) -> Path:
    (tmp_path / "README.md").write_text("hello project\n", encoding="utf-8")
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "app.py").write_text(
        "before\nneedle appears here\nafter\n", encoding="utf-8"
    )
    (tmp_path / "image.bin").write_bytes(b"\x00\x01\x02")
    (tmp_path / "large.txt").write_text("x" * (1024 * 1024 + 1), encoding="utf-8")
    (tmp_path / ".git").mkdir()
    (tmp_path / ".git" / "config").write_text("needle\n", encoding="utf-8")
    (tmp_path / "node_modules").mkdir()
    (tmp_path / "node_modules" / "pkg.js").write_text("needle\n", encoding="utf-8")
    for ignored_name in ("build", "dist", ".next"):
        ignored_dir = tmp_path / ignored_name
        ignored_dir.mkdir()
        (ignored_dir / "generated.js").write_text("needle\n", encoding="utf-8")
    return tmp_path


@pytest.fixture
def outside_file(tmp_path: Path, project_root: Path) -> Path:
    outside_dir = tmp_path.parent / f"{tmp_path.name}-outside"
    outside_dir.mkdir()
    outside = outside_dir / "outside.txt"
    outside.write_text("outside project\n", encoding="utf-8")
    (project_root / "linked.txt").symlink_to(outside)
    return outside


def import_server(monkeypatch: pytest.MonkeyPatch, root: Path):
    monkeypatch.setenv("PROJECT_ROOT", str(root))
    sys.modules.pop("server", None)
    return importlib.import_module("server")


def test_list_files_returns_metadata_and_recursive_paths(
    monkeypatch: pytest.MonkeyPatch, project_root: Path
):
    server = import_server(monkeypatch, project_root)

    result = server.reader.list_files("", recursive=True)

    assert {item["relative_path"] for item in result["files"]} >= {
        "README.md",
        "src/app.py",
    }
    readme = next(item for item in result["files"] if item["relative_path"] == "README.md")
    assert readme["name"] == "README.md"
    assert readme["type"] == "file"
    assert isinstance(readme["size_bytes"], int)
    assert isinstance(readme["modified_time"], str)


def test_read_file_returns_utf8_text(
    monkeypatch: pytest.MonkeyPatch, project_root: Path
):
    server = import_server(monkeypatch, project_root)

    result = server.reader.read_file("README.md")

    assert result["content"] == "hello project\n"
    assert result["path"] == "README.md"


def test_rejects_absolute_and_parent_paths(
    monkeypatch: pytest.MonkeyPatch, project_root: Path
):
    server = import_server(monkeypatch, project_root)

    assert "outside PROJECT_ROOT" in server.reader.read_file("../outside.txt")["error"]
    assert "relative" in server.reader.read_file(str(project_root / "README.md"))["error"]


def test_rejects_outside_symlink(
    monkeypatch: pytest.MonkeyPatch, project_root: Path, outside_file: Path
):
    server = import_server(monkeypatch, project_root)

    result = server.reader.read_file("linked.txt")

    assert "outside PROJECT_ROOT" in result["error"]


def test_rejects_non_text_and_oversized_files(
    monkeypatch: pytest.MonkeyPatch, project_root: Path
):
    server = import_server(monkeypatch, project_root)

    assert "text file" in server.reader.read_file("image.bin")["error"]
    assert "maximum" in server.reader.read_file("large.txt")["error"]


def test_missing_project_root_fails_clearly(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    server = import_server(monkeypatch, tmp_path)
    monkeypatch.delenv("PROJECT_ROOT", raising=False)

    with pytest.raises(RuntimeError, match="PROJECT_ROOT"):
        server.load_project_root()


def test_search_returns_line_numbers_and_nearby_context(
    monkeypatch: pytest.MonkeyPatch, project_root: Path
):
    server = import_server(monkeypatch, project_root)

    result = server.reader.search_files("needle")

    assert result["query"] == "needle"
    match = next(item for item in result["matches"] if item["path"] == "src/app.py")
    assert match["line_number"] == 2
    assert "needle" in match["line"]
    assert match["context_before"] == ["before"]
    assert match["context_after"] == ["after"]


def test_search_ignores_generated_and_vendor_directories(
    monkeypatch: pytest.MonkeyPatch, project_root: Path
):
    server = import_server(monkeypatch, project_root)

    result = server.reader.search_files("needle")
    paths = {item["path"] for item in result["matches"]}

    assert ".git/config" not in paths
    assert "node_modules/pkg.js" not in paths
    assert "build/generated.js" not in paths
    assert "dist/generated.js" not in paths
    assert ".next/generated.js" not in paths


def test_search_rejects_an_empty_query(
    monkeypatch: pytest.MonkeyPatch, project_root: Path
):
    server = import_server(monkeypatch, project_root)

    result = server.reader.search_files("   ")

    assert "query must not be empty" in result["error"]


def test_search_bounds_result_count(
    monkeypatch: pytest.MonkeyPatch, project_root: Path
):
    (project_root / "src" / "many.py").write_text("needle\n" * 205, encoding="utf-8")
    server = import_server(monkeypatch, project_root)

    result = server.reader.search_files("needle")

    assert len(result["matches"]) == 200
    assert result["truncated"] is True


def test_registered_tools_are_exactly_read_only_file_tools(
    monkeypatch: pytest.MonkeyPatch, project_root: Path
):
    server = import_server(monkeypatch, project_root)

    assert set(server.mcp._tool_manager._tools) == {
        "list_files",
        "read_file",
        "search_files",
    }


def test_recursive_listing_skips_vendor_directories(monkeypatch, project_root):
    server = import_server(monkeypatch, project_root)
    result = server.reader.list_files("", recursive=True)
    paths = {item["relative_path"] for item in result["files"]}
    assert "src/app.py" in paths
    assert not any(p.startswith(("node_modules/", ".git/", "build/", "dist/", ".next/")) for p in paths)


def test_listing_default_is_bounded_and_pages_without_duplicates(monkeypatch, tmp_path):
    for i in range(405):
        (tmp_path / f"{i:04}.txt").touch()
    server = import_server(monkeypatch, tmp_path)
    result = server.reader.list_files()
    assert len(result["files"]) == 200
    paths = []
    while True:
        paths.extend(item["relative_path"] for item in result["files"])
        if result["next_cursor"] is None:
            break
        result = server.reader.list_files(cursor=result["next_cursor"])
    assert paths == [f"{i:04}.txt" for i in range(405)]


def test_read_pages_preserve_newlines_and_long_unicode_lines(monkeypatch, tmp_path):
    text = "一\n二\n" + "汉😀\"\\" * 50000 + "\nlast\n"
    (tmp_path / "long.txt").write_text(text, encoding="utf-8")
    server = import_server(monkeypatch, tmp_path)
    line, column, pieces = 1, 0, []
    for _ in range(100):
        result = server.reader.read_file("long.txt", start_line=line, start_column=column, max_lines=2)
        assert len(json.dumps(result).encode()) < 512 * 1024
        pieces.append(result["content"])
        if not result["truncated"]:
            break
        line, column = result["next_line"], result["next_column"]
    else:
        pytest.fail("read pagination did not terminate")
    assert "".join(pieces) == text


def test_search_pages_and_reports_exact_last_page(monkeypatch, tmp_path):
    (tmp_path / "matches.txt").write_text("needle\n" * 5, encoding="utf-8")
    server = import_server(monkeypatch, tmp_path)
    first = server.reader.search_files("needle", limit=3)
    second = server.reader.search_files("needle", limit=3, cursor=first["next_cursor"])
    assert [m["line_number"] for m in first["matches"]] == [1, 2, 3]
    assert [m["line_number"] for m in second["matches"]] == [4, 5]
    assert second["next_cursor"] is None
    assert second["truncated"] is False


def test_search_long_lines_stay_small_and_show_match(monkeypatch, tmp_path):
    (tmp_path / "long.json").write_text("a" * 300000 + "needle" + "b" * 300000, encoding="utf-8")
    server = import_server(monkeypatch, tmp_path)
    result = server.reader.search_files("needle")
    assert "needle" in result["matches"][0]["line"]
    assert result["matches"][0]["line_truncated"] is True
    assert len(json.dumps(result).encode()) < 512 * 1024


def test_long_search_query_remains_whole_in_excerpt(monkeypatch, tmp_path):
    query = "x" * 512
    (tmp_path / "query.txt").write_text("a" * 300 + query + "b" * 300)
    server = import_server(monkeypatch, tmp_path)
    assert query in server.reader.search_files(query)["matches"][0]["line"]


@pytest.mark.parametrize("cursor", ["-1", "bad", "9" * 100])
def test_invalid_cursors_return_clear_errors(monkeypatch, tmp_path, cursor):
    server = import_server(monkeypatch, tmp_path)
    assert "error" in server.reader.list_files(cursor=cursor)
    assert "error" in server.reader.search_files("x", cursor=cursor)


def test_invalid_page_sizes_and_ranges_return_errors(monkeypatch, tmp_path):
    server = import_server(monkeypatch, tmp_path)
    assert "error" in server.reader.list_files(limit=0)
    assert "error" in server.reader.list_files(limit=501)
    assert "error" in server.reader.search_files("x", limit=201)
    assert "error" in server.reader.read_file("x.txt", start_line=0)
    assert "error" in server.reader.read_file("x.txt", start_column=-1)


def test_worst_case_search_envelope_stays_below_tunnel_limit(monkeypatch, tmp_path):
    (tmp_path / "escaped.txt").write_text(("\x01" * 4000 + "needle\n") * 205, encoding="utf-8")
    server = import_server(monkeypatch, tmp_path)
    result = server.reader.search_files("needle")
    assert result["matches"]
    assert len(json.dumps(result).encode()) <= 512 * 1024
    numbers = []
    while True:
        numbers.extend(match["line_number"] for match in result["matches"])
        assert len(json.dumps(result).encode()) <= 512 * 1024
        if result["next_cursor"] is None:
            break
        result = server.reader.search_files("needle", cursor=result["next_cursor"])
    assert numbers == list(range(1, 206))


def test_search_reports_skipped_large_files(monkeypatch, project_root):
    server = import_server(monkeypatch, project_root)
    result = server.reader.search_files("needle")
    assert result["skipped_files"] == 1
    assert not result["truncated"]


def test_read_single_line_larger_than_page_preserves_all_characters(monkeypatch, tmp_path):
    text = "x" * 32769
    (tmp_path / "long.txt").write_text(text)
    server = import_server(monkeypatch, tmp_path)
    first = server.reader.read_file("long.txt")
    assert first["next_line"] == 1
    assert first["next_column"] == 32768
    last = server.reader.read_file("long.txt", start_line=1, start_column=32768)
    assert first["content"] + last["content"] == text
    assert last["next_line"] is None


def test_final_guard_rejects_oversized_response(monkeypatch, tmp_path):
    server = import_server(monkeypatch, tmp_path)
    result = server._safe_call(lambda: {"content": "\x01" * 1000000})
    assert "error" in result
    assert len(json.dumps(result).encode()) < 1024
