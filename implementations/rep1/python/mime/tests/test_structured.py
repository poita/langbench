import pytest

from mimedump.structured import parse_structured


def params(raw):
    return parse_structured(raw).params


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ('x; filename="report.pdf"', "report.pdf"),
        ("x; filename*=utf-8''a%C3%A9.txt", "aé.txt"),
        ('x; filename*0="long"; filename*1="name.txt"', "longname.txt"),
        ('x; filename*0*=utf-8\'\'a%C3%A9; filename*1=".txt"', "aé.txt"),
        ('x; filename="=?utf-8?Q?a=C3=A9.txt?="', "aé.txt"),
        ("x; filename=two words.bin", "two words.bin"),
        ("x; filename*=''caf%E9.txt", "caf�.txt"),
        ("x; filename*0=a; filename*2=c; filename*10=j", "acj"),
        ('x; filename="a\\\\"; x=1', "a\\"),
        ("x; filename*07=b; filename*0=a", "ab"),
        ("x; filename*0=a; filename*00=z", "a"),
        ("x; filename*1=b; filename*1*=%41; filename*0=a", "ab"),
        ("x; filename=plain; filename*=utf-8''ext", "ext"),
        ("x; filename*=utf-8''ext; filename*0=num", "num"),
        ("x; filename*=abc%20d", "abc d"),
        ("x; filename*=utf-8'en'100%25%zz", "100%%zz"),
        ("x; filename=a; filename=b", "a"),
    ],
)
def test_filename(raw, expected):
    assert params(raw)["filename"] == expected


def test_value_and_params():
    sv = parse_structured('  Text/Plain ; Charset = "utf-8" ; no-equals; x=y ')
    assert sv.value == "text/plain"
    assert sv.params == {"charset": "utf-8", "x": "y"}


def test_semicolon_inside_quotes_and_unclosed_quote():
    assert params('x; a="b;c"; d=e')["a"] == "b;c"
    assert params('x; a="b;c')["a"] == "b;c"
    assert params('x; a="b" junk; d=e') == {"a": "b", "d": "e"}


def test_star_names_that_are_not_segments_stay_plain():
    assert params("x; *0=a; f*x=b") == {"*0": "a", "f*x": "b"}


def test_parentheses_are_ordinary():
    assert params("x; boundary=a(b)c")["boundary"] == "a(b)c"
