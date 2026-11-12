import pytest

from tomlcodec import TomlDecodeError, loads, to_tagged_json


def v(kind, value):
    return '{"type":"%s","value":"%s"}' % (kind, value)


@pytest.mark.parametrize(
    "doc, expected",
    [
        ("", "{}"),
        ("# only a comment\n", "{}"),
        ('a = "x"', '{"a":%s}' % v("string", "x")),
        ("a = 'C:\\path'", '{"a":%s}' % v("string", "C:\\\\path")),
        ("a = 42\n", '{"a":%s}' % v("integer", "42")),
        ("a = +1_000", '{"a":%s}' % v("integer", "1000")),
        ("a = 0xDEAD_beef", '{"a":%s}' % v("integer", "3735928559")),
        ("a = 0o755", '{"a":%s}' % v("integer", "493")),
        ("a = 0b101", '{"a":%s}' % v("integer", "5")),
        ("a = -9223372036854775808", '{"a":%s}' % v("integer", "-9223372036854775808")),
        ("a = true", '{"a":%s}' % v("bool", "true")),
        ("a = 1.0", '{"a":%s}' % v("float", "1.0000000000000000e+00")),
        ("a = 3.1415", '{"a":%s}' % v("float", "3.1415000000000002e+00")),
        ("a = -0.0", '{"a":%s}' % v("float", "-0.0000000000000000e+00")),
        ("a = 5e-324", '{"a":%s}' % v("float", "4.9406564584124654e-324")),
        ("a = 1e999", '{"a":%s}' % v("float", "inf")),
        ("a = -inf", '{"a":%s}' % v("float", "-inf")),
        ("a = -nan", '{"a":%s}' % v("float", "nan")),
        ("a = 1987-07-05 17:45:00z", '{"a":%s}' % v("datetime", "1987-07-05T17:45:00Z")),
        ("a = 1987-07-05T17:45:56.600+08:00", '{"a":%s}' % v("datetime", "1987-07-05T17:45:56.6+08:00")),
        ("a = 1979-05-27t07:32:00-00:00", '{"a":%s}' % v("datetime", "1979-05-27T07:32:00Z")),
        ("a = 1979-05-27T07:32:00.000", '{"a":%s}' % v("datetime-local", "1979-05-27T07:32:00")),
        ("a = 1979-05-27 # c", '{"a":%s}' % v("date-local", "1979-05-27")),
        ("a = 07:32:00.50", '{"a":%s}' % v("time-local", "07:32:00.5")),
    ],
)
def test_scalars(decode, doc, expected):
    assert decode(doc) == expected


def test_worked_example(decode):
    doc = (
        'name = "Tom"\ndob = 1979-05-27T07:32:00-08:00\n\n[db]\nports = [ 8001, 8002 ]\n'
        'enabled = true\n\n[[fruit]]\nname = "apple"\n\n[[fruit]]\nname = "banana"\n'
    )
    assert decode(doc) == (
        '{"db":{"enabled":{"type":"bool","value":"true"},"ports":[{"type":"integer","value":"8001"},'
        '{"type":"integer","value":"8002"}]},"dob":{"type":"datetime","value":"1979-05-27T07:32:00-08:00"},'
        '"fruit":[{"name":{"type":"string","value":"apple"}},{"name":{"type":"string","value":"banana"}}],'
        '"name":{"type":"string","value":"Tom"}}'
    )


def test_keys_sorted_by_code_point(decode):
    out = decode('"é" = 1\na = 1\nA = 1\n"" = 1\n')
    assert out.index('"":') < out.index('"A":') < out.index('"a":') < out.index('"é":')


@pytest.mark.parametrize(
    "doc, text",
    [
        (r'a = "tab\there"', "tab\there"),
        (r'a = "\u00e9\U0001F600"', "é\U0001f600"),
        ('a = """\nline1\r\nline2"""', "line1\nline2"),
        ('a = """a \\\n   b"""', "a b"),
        ('a = """x""""', 'x"'),
        ('a = """x"""""', 'x""'),
        ("a = '''\nraw \\n'''", "raw \\n"),
        (r'a = "\u0000"', "\x00"),
    ],
)
def test_string_forms(doc, text):
    assert loads(doc)["a"].text == text


def test_json_escaping(decode):
    assert decode(r'a = "\u0000\u001f\u007f\"\\é"') == (
        '{"a":{"type":"string","value":"\\u0000\\u001f\x7f\\"\\\\é"}}'
    )


def test_dotted_and_headers(decode):
    doc = "[fruit]\napple.color = 'red'\n[fruit.apple.texture]\nsmooth = true\n[x.y.z]\n[x]\nq = 1\n"
    out = decode(doc)
    assert '"color"' in out and '"texture"' in out


def test_array_of_tables_subtables():
    tree = loads("[[f]]\nn=1\n[f.p]\nc='r'\n[[f.v]]\nn=2\n[[f]]\nn=3\n")
    assert len(tree["f"]) == 2
    assert "p" in tree["f"][0] and "v" in tree["f"][0]
    assert "p" not in tree["f"][1]


def test_inline_table_and_array_with_comments():
    tree = loads("a = { b = [ # c\n 1, 2, # d\n ], c.d = 3 }\n")
    assert [e.text for e in tree["a"]["b"]] == ["1", "2"]
    assert tree["a"]["c"]["d"].text == "3"


def test_bytes_input():
    assert loads(b"a = 1\r\nb = 2\r\n")["b"].text == "2"


INVALID = [
    "a = ",
    "a = 1 b = 2",
    "a = 1\na = 2",
    "a = 01",
    "a = +01",
    "a = 1__0",
    "a = _1",
    "a = 1_",
    "a = 0X1",
    "a = -0x1",
    "a = 0xFFFFFFFFFFFFFFFF",
    "a = 9223372036854775808",
    "a = .5",
    "a = 5.",
    "a = 1.e2",
    "a = 1e",
    "a = Inf",
    "a = TRUE",
    "a = 1987-7-05",
    "a = 1987-02-30",
    "a = 1900-02-29",
    "a = 0000-01-01",
    "a = 12:30",
    "a = 12:30:60",
    "a = 1987-07-05T17:45:00+24:00",
    "a = ١٢٣",
    "a = 1979-05-2٧",
    'a = "\\x"',
    'a = "\\ud800"',
    'a = "\\U00110000"',
    'a = "abc',
    'a = "a\nb"',
    "a = '''x''''''",
    'a = """x""""""',
    'a = "\x7f"',
    'a = "\x00"',
    "a = 1 # \x7f",
    "a = 1 # \x01",
    "a = 1\rb = 2",
    "a = 'x\ry'",
    "a = [1,,2]",
    "a = [,1]",
    "a = {b=1,}",
    "a = {b=1\n}",
    "a = {\nb=1}",
    '"""a""" = 1',
    "[a]\n[a]",
    "a.b = 1\n[a]",
    "[fruit]\napple.color = 'r'\n[fruit.apple]",
    "a = {b=1}\n[a.c]",
    "a = {b=1}\na.c = 2",
    "a = [1]\n[[a]]",
    "a = 1\n[a]",
    "[ [a] ]",
    "[[a] ]",
    "[a.b]\n[[a.b]]",
    "[a.b.c]\nz=9\n[a]\nb.c.t=1",
    "[a]\nb.c=1\n[a.b]",
    "\ufeffa = 1",
    "[a]]",
    "a = 1\n[",
    "=1",
    "a.=1",
    ".a=1",
]


@pytest.mark.parametrize("doc", INVALID)
def test_invalid(doc):
    with pytest.raises(TomlDecodeError):
        loads(doc)


@pytest.mark.parametrize("data", [b"\xff", b"a = '\xc0\x80'", b"a = '\xed\xa0\x80'", b"\xff\xfea\x00"])
def test_invalid_utf8(data):
    with pytest.raises(TomlDecodeError):
        loads(data)


def test_error_position():
    with pytest.raises(TomlDecodeError) as info:
        loads("a = 1\nb = oops\n")
    assert info.value.lineno == 2


def test_deep_nesting():
    import sys

    old = sys.getrecursionlimit()
    sys.setrecursionlimit(50_000)
    try:
        depth = 400
        tree = loads("a = " + "[" * depth + "]" * depth)
        assert tree["a"]
    finally:
        sys.setrecursionlimit(old)
