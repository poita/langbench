"""Hashing, paths, the virtual file system and the glob matcher."""

import pytest

from kiln import VirtualFS, fnv1a64, hash_hex
from kiln.globs import GlobSyntaxError, compile_glob
from kiln.paths import is_generated, is_phony_ref, is_workspace_path


def test_fnv1a_known_values():
    assert hash_hex(b"") == b"cbf29ce484222325"
    assert hash_hex(b"hello\n") == b"a9bc80cca21f28b3"
    assert hash_hex(b"abc\n") == b"fc17b183ee074373"
    assert fnv1a64(b"") == 0xCBF29CE484222325


@pytest.mark.parametrize("path", ["a", "a/b.c", "src/x+y-z_1", "a" * 255, ".hidden", "a/..b"])
def test_valid_workspace_paths(path):
    assert is_workspace_path(path.encode())


@pytest.mark.parametrize(
    "path", ["", "/a", "a/", "a//b", ".", "..", "a/./b", "a/../b", "a b", "a*", "a@b", "a" * 256, "é"]
)
def test_invalid_workspace_paths(path):
    assert not is_workspace_path(path.encode())


def test_path_length_limit():
    assert not is_workspace_path(b"/".join([b"a" * 200] * 6))  # > 1024 bytes


def test_phony_and_generated():
    assert is_phony_ref(b"@all") and is_phony_ref(b"@_x1")
    assert not is_phony_ref(b"@") and not is_phony_ref(b"@1a") and not is_phony_ref(b"all")
    assert is_generated(b"out/x") and not is_generated(b"output/x") and not is_generated(b"src/out/x")


class TestVirtualFS:
    def test_hash_is_cached_until_content_changes(self):
        fs = VirtualFS({b"a": b"hello\n"})
        assert fs.hash(b"a") == b"a9bc80cca21f28b3"
        fs.write(b"a", b"abc\n")
        assert fs.hash(b"a") == b"fc17b183ee074373"
        assert fs.hash(b"missing") is None

    def test_glob_skips_generated_and_state(self):
        fs = VirtualFS({b"src/a.txt": b"", b"out/a.txt": b"", b".kiln-state": b"", b"b.txt": b""})
        assert fs.glob(compile_glob(b"**")) == [b"b.txt", b"src/a.txt"]

    def test_glob_index_tracks_mutation(self):
        fs = VirtualFS({b"src/a.txt": b""})
        assert fs.glob(compile_glob(b"src/*")) == [b"src/a.txt"]
        fs.write(b"src/b.txt", b"")
        assert fs.glob(compile_glob(b"src/*")) == [b"src/a.txt", b"src/b.txt"]
        fs.delete(b"src/a.txt")
        assert fs.glob(compile_glob(b"src/*")) == [b"src/b.txt"]

    def test_remove_generated(self):
        fs = VirtualFS({b"out/a": b"", b".kiln-state": b"", b"src/a": b"", b"out": b""})
        assert fs.remove_generated() == [b".kiln-state", b"out", b"out/a"]
        assert fs.paths() == [b"src/a"]

    def test_directory_roundtrip(self, tmp_path):
        (tmp_path / "in" / "sub").mkdir(parents=True)
        (tmp_path / "in" / "session.txt").write_bytes(b"build\n")
        (tmp_path / "in" / "sub" / "f.bin").write_bytes(b"\x00\xff")
        fs = VirtualFS.from_directory(tmp_path / "in")
        assert fs.paths() == [b"sub/f.bin"]
        fs.write_to_directory(tmp_path / "out")
        assert (tmp_path / "out" / "sub" / "f.bin").read_bytes() == b"\x00\xff"


class TestGlob:
    @pytest.mark.parametrize(
        "pattern,candidate,expected",
        [
            ("src/*.txt", "src/a.txt", True),
            ("src/*.txt", "src/.txt", True),
            ("src/*.txt", "src/sub/a.txt", False),
            ("src/*.txt", "a.txt", False),
            ("src/**", "src/a.txt", True),
            ("src/**", "src/x/y/z.txt", True),
            ("src/**", "src", True),
            ("src/**", "srcx", False),
            ("src/**", "other/a.txt", False),
            ("**/*.txt", "a.txt", True),
            ("**/*.txt", "a/b/c.txt", True),
            ("**/*.txt", "a.text", False),
            ("src/**/t_*.txt", "src/t_1.txt", True),
            ("src/**/t_*.txt", "src/a/b/t_2.txt", True),
            ("src/**/t_*.txt", "src/t.txt", False),
            ("src/?.txt", "src/a.txt", True),
            ("src/?.txt", "src/ab.txt", False),
            ("src/[ab]*.txt", "src/a1.txt", True),
            ("src/[ab]*.txt", "src/c.txt", False),
            ("src/[!ab]*.txt", "src/c.txt", True),
            ("src/[!ab]*.txt", "src/a.txt", False),
            ("src/[0-9].txt", "src/7.txt", True),
            ("src/[0-9].txt", "src/x.txt", False),
            ("a**b", "axyzb", True),
            ("a**b", "ab", True),
            ("a**b", "a/b", False),
            ("[-a]", "-", True),
            ("[a-]", "-", True),
            ("[*?]", "?", True),
            ("*", "", True),
            ("**", "", True),
            ("?", "", False),
            ("*", "a//b", False),
            ("**", "a//b", True),
            ("a/*", "a/", True),
        ],
    )
    def test_match(self, pattern, candidate, expected):
        assert compile_glob(pattern.encode()).match(candidate.encode()) is expected

    @pytest.mark.parametrize(
        "pattern", ["", "/a", "a/", "a//b", "[", "[a", "[]", "[!]", "[z-a]", "a/[b", "[]]"]
    )
    def test_malformed(self, pattern):
        with pytest.raises(GlobSyntaxError):
            compile_glob(pattern.encode())

    def test_star_backtracking(self):
        assert compile_glob(b"*a*a*b").match(b"xaxaxaxb")
        assert not compile_glob(b"*a*a*b").match(b"xaxaxax")
