import pytest

from jsoncanon import JSONError, MAX_DEPTH, Number, Object, parse


def invalid(data):
    with pytest.raises(JSONError):
        parse(data)


@pytest.mark.parametrize(
    "doc",
    [b"", b"  \n", b"[1,]", b"{\"a\":1,}", b"[,1]", b"[1 2]", b"{\"a\" 1}", b"{a:1}",
     b"{1:2}", b"'a'", b"/*c*/1", b"True", b"NaN", b"Infinity", b"-Infinity", b"nul",
     b"01", b"+1", b"-", b"1.", b".5", b"1e", b"1e+", b"1E+-5", b"1e5e5", b"0x1",
     b"- 1", b"1 .5", b"1 2", b"[]x", b"1\x00", b"\x0c1", b"\x0b1", b"\xc2\xa01",
     b"\xe2\x80\xa81", b"[", b"[1", b"{\"a\":", b"\"abc", b"[\"\\", b"\"\\x\"",
     b"\"\\u12\"", b"\"\\u00G0\"", "\"\\u\uff11\uff11\uff11\uff11\"".encode(),
     b"\"\t\"", b"\"\n\"", b"\"\x00\"", b"\"\\ud800\"", b"\"\\ud800\\u0041\"",
     b"\"\\ud800\\ue000\"", b"\"\\ud800\\udbff\"", b"\"\\udc00\"", b"\"\\ud800x\"",
     b"{\"\\ud800\":1}", b"{\"a\":\"\\ud800\",\"a\":1}", b"{\"a\":[1,],\"a\":1}",
     b"1\xd9\xa2", "\u0662".encode(), "\uff11".encode(), "\u00b2".encode()],
)
def test_invalid_documents(doc):
    invalid(doc)


@pytest.mark.parametrize(
    "doc",
    [b"\xef\xbb\xbf1", b"\"\xc0\x80\"", b"\"\xed\xa0\x80\"", b"\"\xf4\x90\x80\x80\"",
     b"\"\xe2\x82\"", b"\"\xff\"", b"\"\x80\""],
)
def test_bad_utf8(doc):
    invalid(doc)


def test_utf8_error_even_in_trailing_position():
    invalid(b"1 \xff")


def test_scalars():
    assert parse(b" true ") is True
    assert parse(b"false") is False
    assert parse(b"null") is None
    assert parse(b'"a\\u0041\\/"') == "aA/"
    assert parse(b'"\\ud83d\\ude00"') == "\U0001f600"
    assert parse(b'"\x7f\xe2\x80\xa8"') == "\x7f\u2028"


def test_whitespace_variants():
    assert parse(b" \t\r\n[ \t\r\n1 \t\r\n, 2\n]\n") == [Number("1"), Number("2")]


@pytest.mark.parametrize(
    "lexeme,expected",
    [("1", "1"), ("-0", "-0"), ("1.0", "1.0"), ("1.50", "1.50"), ("1E5", "1e5"),
     ("1e+05", "1e5"), ("1e-007", "1e-7"), ("1e-0", "1e0"), ("1E+00", "1e0"),
     ("-0.0", "-0.0"), ("0e0", "0e0"), ("2.5E-000789", "2.5e-789"),
     ("1" * 400, "1" * 400)],
)
def test_numbers(lexeme, expected):
    result = parse(lexeme.encode())
    assert isinstance(result, Number)
    assert result == expected


def test_object_keeps_duplicates_in_order():
    obj = parse(b'{"b":1,"a":2,"b":3}')
    assert isinstance(obj, Object)
    assert [k for k, _ in obj.members] == ["b", "a", "b"]


def test_depth_limit():
    parse(b"[" * MAX_DEPTH + b"]" * MAX_DEPTH)
    invalid(b"[" * (MAX_DEPTH + 1) + b"]" * (MAX_DEPTH + 1))
    invalid(b"[" * MAX_DEPTH + b"{}" + b"]" * MAX_DEPTH)
    invalid(b"[" * 100000)


def test_str_input_accepted():
    assert parse("[1]") == [Number("1")]
