import pytest

from kiln.glob import MalformedPattern, compile_pattern
from kiln.hashing import hash_hex
from kiln.values import sort_key, values_equal, wrap


def test_fnv_known_vectors():
    assert hash_hex(b"") == b"cbf29ce484222325"
    assert hash_hex(b"hello\n") == b"a9bc80cca21f28b3"
    assert hash_hex(b"abc\n") == b"fc17b183ee074373"


def test_bool_is_not_int():
    assert not values_equal(True, 1)
    assert not values_equal([True], [1])
    assert values_equal([1, [b"a"]], [1, [b"a"]])


def test_total_order():
    mixed = [[1], b"a", 3, True, False, b"", [], 1]
    assert sorted(mixed, key=sort_key) == [False, True, 1, 3, b"", b"a", [], [1]]


def test_wrap():
    assert wrap(2**63) == -(2**63)
    assert wrap(-(2**63) - 1) == 2**63 - 1


@pytest.mark.parametrize(
    "pattern,yes,no",
    [
        ("src/*.txt", ["src/a.txt", "src/.txt"], ["src/sub/a.txt", "a.txt"]),
        ("src/**", ["src/a.txt", "src/x/y/z.txt", "src"], ["other/a.txt", "srcx"]),
        ("**/*.txt", ["a.txt", "src/a.txt", "a/b/c.txt"], ["a.text"]),
        ("src/**/t_*.txt", ["src/t_1.txt", "src/a/b/t_2.txt"], ["src/t.txt"]),
        ("src/?.txt", ["src/a.txt"], ["src/ab.txt"]),
        ("src/[ab]*.txt", ["src/a1.txt", "src/b.txt"], ["src/c.txt"]),
        ("src/[!ab]*.txt", ["src/c.txt"], ["src/a.txt"]),
        ("src/[0-9].txt", ["src/7.txt"], ["src/x.txt"]),
        ("a**b", ["axyzb", "ab"], ["a/b"]),
        ("[-a]", ["-", "a"], ["b"]),
        ("*", ["", "x"], ["a/b", "a//b"]),
        ("**", ["", "a/b", "a//b"], []),
        ("?", ["x"], [""]),
    ],
)
def test_glob_examples(pattern, yes, no):
    p = compile_pattern(pattern.encode())
    for s in yes:
        assert p.match(s.encode()), s
    for s in no:
        assert not p.match(s.encode()), s


@pytest.mark.parametrize(
    "pattern", ["", "/a", "a/", "a//b", "[", "[]", "[!]", "[b-a]", "a[bc", "[]a]"]
)
def test_malformed_patterns(pattern):
    with pytest.raises(MalformedPattern):
        compile_pattern(pattern.encode())


def test_literal_prefix():
    assert compile_pattern(b"src/lib/*.c").prefix == b"src/lib/"
    assert compile_pattern(b"src/t_*.c").prefix == b"src/t_"
    assert compile_pattern(b"src/**").prefix == b"src"
    assert compile_pattern(b"**/x").prefix == b""
    assert compile_pattern(b"a/b").prefix == b"a/b"


def test_star_backtracking_is_not_exponential():
    p = compile_pattern(b"*a*a*a*a*a*a*a*a*b")
    assert not p.match(b"a" * 5000)
