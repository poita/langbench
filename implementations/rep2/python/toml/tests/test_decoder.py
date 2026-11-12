import pytest

import tomlcodec
from tomlcodec import TomlDecodeError, loads


def v(type_, value):
    return f'{{"type":"{type_}","value":"{value}"}}'


def test_empty_document():
    assert tomlcodec.decode("") == "{}"
    assert tomlcodec.decode("# just a comment\n\n  \n") == "{}"


def test_spec_example():
    doc = """name = "Tom"
dob = 1979-05-27T07:32:00-08:00

[db]
ports = [ 8001, 8002 ]
enabled = true

[[fruit]]
name = "apple"

[[fruit]]
name = "banana"
"""
    assert tomlcodec.decode(doc) == (
        '{"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer",'
        '"value":"8001"},{"type":"integer","value":"8002"}]},"dob":{"type":"datetime",'
        '"value":"1979-05-27T07:32:00-08:00"},"fruit":[{"name":{"type":"string",'
        '"value":"apple"}},{"name":{"type":"string","value":"banana"}}],"name":'
        '{"type":"string","value":"Tom"}}'
    )


def test_tree_api():
    t = loads(b'a.b = 1\n[c]\nd = "x"\n')
    assert t["a"]["b"].text == "1"
    assert t["c"]["d"].type == "string"
    assert list(t) == ["a", "c"]


@pytest.mark.parametrize(
    "text, expected",
    [
        ("0", "0"),
        ("+17", "17"),
        ("-0", "0"),
        ("1_000", "1000"),
        ("0xDEAD_beef", "3735928559"),
        ("0o755", "493"),
        ("0b1101", "13"),
        ("9223372036854775807", "9223372036854775807"),
        ("-9223372036854775808", "-9223372036854775808"),
    ],
)
def test_integers(text, expected):
    assert tomlcodec.decode(f"a = {text}") == '{"a":' + v("integer", expected) + "}"


@pytest.mark.parametrize(
    "text",
    ["01", "+01", "1__0", "_1", "1_", "0X1", "-0x1", "0xFFFFFFFFFFFFFFFF",
     "9223372036854775808", "-9223372036854775809", "0b2", "0o8", "١٢٣"],
)
def test_bad_integers(text):
    with pytest.raises(TomlDecodeError):
        loads(f"a = {text}")


@pytest.mark.parametrize(
    "text, expected",
    [
        ("1.0", "1.0000000000000000e+00"),
        ("3.1415", "3.1415000000000002e+00"),
        ("-0.0", "-0.0000000000000000e+00"),
        ("0e0", "0.0000000000000000e+00"),
        ("1e308", "1.0000000000000000e+308"),
        ("6.626e-34", "6.6259999999999998e-34"),
        ("5e-324", "4.9406564584124654e-324"),
        ("1e999", "inf"),
        ("-1e999", "-inf"),
        ("1e-999", "0.0000000000000000e+00"),
        ("0e00", "0.0000000000000000e+00"),
        ("1_0.0_1", "1.0010000000000000e+01"),
        ("inf", "inf"),
        ("+inf", "inf"),
        ("-inf", "-inf"),
        ("nan", "nan"),
        ("-nan", "nan"),
    ],
)
def test_floats(text, expected):
    assert tomlcodec.decode(f"a = {text}") == '{"a":' + v("float", expected) + "}"


@pytest.mark.parametrize("text", [".5", "5.", "1.e2", "1e", "01.5", "Inf", "NaN", "1._5", "1e_5"])
def test_bad_floats(text):
    with pytest.raises(TomlDecodeError):
        loads(f"a = {text}")


@pytest.mark.parametrize(
    "text, type_, expected",
    [
        ("1987-07-05 17:45:00z", "datetime", "1987-07-05T17:45:00Z"),
        ("1987-07-05T17:45:56.600+08:00", "datetime", "1987-07-05T17:45:56.6+08:00"),
        ("1979-05-27t07:32:00-00:00", "datetime", "1979-05-27T07:32:00Z"),
        ("1979-05-27T07:32:00.000", "datetime-local", "1979-05-27T07:32:00"),
        ("1979-05-27", "date-local", "1979-05-27"),
        ("07:32:00.50", "time-local", "07:32:00.5"),
        ("2000-02-29", "date-local", "2000-02-29"),
    ],
)
def test_datetimes(text, type_, expected):
    assert tomlcodec.decode(f"a = {text}") == '{"a":' + v(type_, expected) + "}"


def test_space_separator_needs_a_time():
    assert tomlcodec.decode("a = 1979-05-27 # c") == '{"a":' + v("date-local", "1979-05-27") + "}"


@pytest.mark.parametrize(
    "text",
    ["1900-02-29", "2023-02-29", "2023-13-01", "2023-00-10", "2023-04-31", "0000-01-01",
     "1987-7-05", "07:32", "24:00:00", "12:60:00", "12:00:60", "1979-05-27T07:32:00+24:00",
     "1979-05-27T07:32:00+00:60", "1979-05-27T", "١٩٧٩-٠٥-٢٧"],
)
def test_bad_datetimes(text):
    with pytest.raises(TomlDecodeError):
        loads(f"a = {text}")


@pytest.mark.parametrize(
    "doc, value",
    [
        (r'a = "tab\there"', "tab\there"),
        (r'a = "\u00e9\U0001F600"', "é😀"),
        (r"a = 'no \escapes'", r"no \escapes"),
        ('a = """\nfirst\nsecond"""', "first\nsecond"),
        ('a = """a\\\n    b"""', "ab"),
        ('a = """x"" y"""', 'x"" y'),
        ('a = """x""""', 'x"'),
        ("a = '''\r\nx\r\ny'''", "x\ny"),
        ("a = '''it''''", "it'"),
        ("a = \"\\u0000\"", "\x00"),
    ],
)
def test_strings(doc, value):
    assert loads(doc)["a"].text == value


@pytest.mark.parametrize(
    "doc",
    [
        'a = "\\x"',
        'a = "\\ud800"',
        'a = "\\U00110000"',
        'a = "\\u12"',
        'a = "unterminated',
        'a = "x\ny"',
        'a = """x""""""',
        "a = 'x\ty\x01'",
        'a = "\x7f"',
        'a = """\\ x"""',
        "# bad \x01 comment",
        "a = 1 # bad \x7f",
        "a = 1\rb = 2",
        "a = \"x\ry\"",
        "\ufeffa = 1",
        "a = 1 b = 2",
        "a =",
        "= 1",
        '"""k""" = 1',
    ],
)
def test_bad_syntax(doc):
    with pytest.raises(TomlDecodeError):
        loads(doc)


def test_invalid_utf8():
    for raw in (b"a = '\xff'", b"a = '\xc0\x80'", b"a = '\xed\xa0\x80'", b"\xff\xfea\x00"):
        with pytest.raises(TomlDecodeError):
            loads(raw)


def test_crlf_line_endings():
    assert loads(b"a = 1\r\nb = 2\r\n")["b"].text == "2"


@pytest.mark.parametrize(
    "doc",
    [
        "a = 1\na = 2",
        "a = 1\n[a]",
        "[a]\n[a]",
        "a.b = 1\n[a]",
        "[a]\nb.c = 1\n[a.b]",
        "[a.b]\n[a]\nb.c = 1",
        "a = {b = 1}\n[a.c]",
        "a = {b = 1}\na.c = 2",
        "a = [1]\n[[a]]",
        "a = [{b = 1}]\n[a.c]",
        "[[a]]\n[a]",
        "a = 1\n[a.b]",
        "a = {b = {c = 1}, b.d = 2}",
        "a = {b = 1,}",
        "a = {b = 1\n}",
        "a = [1,,2]",
        "a = [,1]",
        "[ [a] ]",
        "[[a] ]",
        "[a]]",
    ],
)
def test_table_conflicts(doc):
    with pytest.raises(TomlDecodeError):
        loads(doc)


@pytest.mark.parametrize(
    "doc",
    [
        "a.b = 1\na.c = 2",
        "[x]\na.b = 1\na.c = 2",
        "[fruit]\napple.color = 'red'\n[fruit.apple.texture]\nsmooth = true",
        "[a.b.c]\n[a]\n",
        "[[a]]\n[a.b]\n[[a.c]]\n[[a]]\n[a.b]",
        "a = {b = [\n1,\n2 # c\n]}",
        "a = {b.c = 1, b.d = 2}",
        "[ a . b ]\n[[ a . c ]]",
        "[a]\n[a.b]\n[a.b.c]",
        "a = [ 1, 'x', [2], {b = 3}, ]",
    ],
)
def test_valid_tables(doc):
    loads(doc)


def test_array_of_tables_attach_to_last_element():
    t = loads("[[f]]\nn = 1\n[f.p]\nx = 1\n[[f.v]]\ny = 1\n[[f]]\nn = 2\n")
    assert len(t["f"]) == 2
    assert "p" in t["f"][0] and "v" in t["f"][0]
    assert "p" not in t["f"][1]


def test_dotted_and_quoted_keys_compare_by_text():
    t = loads("\"a\" = 1\n'b' = 2\n\"\" = 3\n\"é\".x = 4\n")
    assert set(t) == {"a", "b", "", "é"}
    with pytest.raises(TomlDecodeError):
        loads("a = 1\n'a' = 2")


def test_error_position():
    with pytest.raises(TomlDecodeError) as info:
        loads("a = 1\nb = nope\n")
    assert info.value.line == 2


def test_deep_nesting():
    import sys

    old = sys.getrecursionlimit()
    sys.setrecursionlimit(20000)
    try:
        depth = 400
        t = loads("a = " + "[" * depth + "]" * depth)
        node = t["a"]
        for _ in range(depth - 1):
            node = node[0]
        assert len(node) == 0
    finally:
        sys.setrecursionlimit(old)


def test_too_deep_is_decode_error_not_crash():
    import sys

    old = sys.getrecursionlimit()
    sys.setrecursionlimit(200)
    try:
        with pytest.raises(TomlDecodeError):
            loads("a = " + "[" * 500 + "]" * 500)
    finally:
        sys.setrecursionlimit(old)
