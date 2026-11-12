import pytest

from jsonschema2020 import uri

BASE = "http://a/b/c/d;p?q"

# RFC 3986 section 5.4.1 / 5.4.2 examples
RFC_CASES = [
    ("g:h", "g:h"),
    ("g", "http://a/b/c/g"),
    ("./g", "http://a/b/c/g"),
    ("g/", "http://a/b/c/g/"),
    ("/g", "http://a/g"),
    ("//g", "http://g"),
    ("?y", "http://a/b/c/d;p?y"),
    ("g?y", "http://a/b/c/g?y"),
    ("#s", "http://a/b/c/d;p?q#s"),
    ("g#s", "http://a/b/c/g#s"),
    ("", "http://a/b/c/d;p?q"),
    (".", "http://a/b/c/"),
    ("./", "http://a/b/c/"),
    ("..", "http://a/b/"),
    ("../g", "http://a/b/g"),
    ("../..", "http://a/"),
    ("../../g", "http://a/g"),
    ("../../../g", "http://a/g"),
    ("/./g", "http://a/g"),
    ("g.", "http://a/b/c/g."),
    ("./../g", "http://a/b/g"),
    ("g;x=1/../y", "http://a/b/c/y"),
]


@pytest.mark.parametrize("ref,expected", RFC_CASES)
def test_rfc_resolution(ref, expected):
    assert uri.resolve(BASE, ref) == expected


def test_empty_base_and_urns():
    assert uri.resolve("", "#foo") == "#foo"
    assert uri.resolve("", "foo.json") == "foo.json"
    assert uri.resolve("urn:uuid:1234", "#/a") == "urn:uuid:1234#/a"
    assert uri.resolve("http://x.test", "foo") == "http://x.test/foo"
    assert uri.resolve("file:///a/b", "c") == "file:///a/c"


def test_split_and_unsplit_roundtrip():
    for text in ["http://u@h:80/p/q?x=1#frag", "urn:a:b", "//h/p", "?q", "#f", "", "a/b"]:
        assert uri.unsplit(uri.split(text)) == text


def test_percent_decode():
    assert uri.percent_decode("a%25b") == "a%b"
    assert uri.percent_decode("%C3%A9") == "é"
    assert uri.percent_decode("%7E%2f") == "~/"
    assert uri.percent_decode("100%") == "100%"
    assert uri.percent_decode("%zz") == "%zz"


def test_json_pointer():
    doc = {"a/b": [10, {"m~n": 5}], "": 1}
    assert uri.evaluate_pointer(doc, "") is doc
    assert uri.evaluate_pointer(doc, "/a~1b/0") == 10
    assert uri.evaluate_pointer(doc, "/a~1b/1/m~0n") == 5
    assert uri.evaluate_pointer(doc, "/") == 1
    for bad in ["/missing", "/a~1b/2", "/a~1b/01", "x", "/a~1b/0/x"]:
        with pytest.raises(uri.PointerError):
            uri.evaluate_pointer(doc, bad)
