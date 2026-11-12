import pytest

from myersdiff import Edit, PatchError, diff, parse_script_lines, patch


def test_example():
    a = list("abcde")
    script = parse_script_lines([" a", "-b", "+B", " c", "+c2", "-d", " e", "+f"])
    assert patch(a, script) == ["a", "B", "c", "c2", "e", "f"]


def test_tag_like_content():
    script = parse_script_lines(["+-x", "  ", "-+1"])
    assert patch([" ", "+1"], script) == ["-x", " "]


def test_roundtrip():
    a = ["x", "y", "", "z"]
    b = ["y", "q", "z", "z"]
    assert patch(a, diff(a, b)) == b


def test_strict_mismatch():
    with pytest.raises(PatchError):
        patch(["a"], [Edit("-", "b")])
    with pytest.raises(PatchError):
        patch(["a", "b"], [Edit(" ", "a")])
    with pytest.raises(PatchError):
        patch([], [Edit(" ", "a")])


def test_bad_tag():
    with pytest.raises(ValueError):
        parse_script_lines(["?x"])
    with pytest.raises(ValueError):
        parse_script_lines([""])
