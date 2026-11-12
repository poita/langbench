import pytest

from sitegen import toml
from sitegen.errors import TomlError


def test_spec_example():
    text = (
        '# a comment\n'
        'title  = "The \\"Big\\" Blog"        # trailing comment\n'
        'posts_per_page = 5\n'
        'draft = false\n'
        'tags = ["one", "two",]\n'
        'motto = "line one\\nline two"\n'
    )
    result = toml.loads(text)
    assert result == {
        "title": 'The "Big" Blog',
        "posts_per_page": 5,
        "draft": False,
        "tags": ["one", "two"],
        "motto": "line one\nline two",
    }
    assert list(result) == ["title", "posts_per_page", "draft", "tags", "motto"]


def test_blank_and_comment_lines_are_ignored():
    assert toml.loads("\n  \t \n   # indented comment\n#x\nk = 1\n") == {"k": 1}


def test_empty_document():
    assert toml.loads("") == {}


@pytest.mark.parametrize(
    "text, expected",
    [
        ("n = 0", 0),
        ("n = -4", -4),
        ("n = 123", 123),
        ("n = true", True),
        ("n = false", False),
        ('n = ""', ""),
        ("n = []", []),
        ('n = [ ]', []),
        ('n = [ "a" , "b" , ]', ["a", "b"]),
        ('n = ["a"]  # c', ["a"]),
        ('s = "a # b"', "a # b"),
        ('s = "\\u00e9t\\u00C9"', "étÉ"),
        ('s = "tab\\there\\r\\\\"', "tab\there\r\\"),
        ('s = "日本語 \'q\'"', "日本語 'q'"),
    ],
)
def test_values(text, expected):
    (value,) = toml.loads(text).values()
    assert value == expected
    assert type(value) is type(expected)


def test_keys_may_contain_dash_and_underscore_and_digits():
    assert toml.loads("a-b_c9 = 1\n\tk\t=\t2") == {"a-b_c9": 1, "k": 2}


def test_integer_is_not_a_bool():
    assert toml.loads("n = 1")["n"] is not True


@pytest.mark.parametrize(
    "text",
    [
        "novalue",
        "= 1",
        "k = ",
        "k = 01",
        "k = +1",
        "k = 1_000",
        "k = 1.5",
        'k = "unterminated',
        'k = "bad \\q escape"',
        'k = "\\u12"',
        "k = [1, 2]",
        'k = ["a" "b"]',
        'k = ["a",, "b"]',
        'k = ["a"',
        'k = "x" extra',
        "[table]",
        "a.b = 1",
        "k = 1\nk = 2",
    ],
)
def test_invalid_input_raises(text):
    with pytest.raises(TomlError):
        toml.loads(text)


def test_error_mentions_line_number():
    with pytest.raises(TomlError, match="line 2"):
        toml.loads("a = 1\nb = ?")
