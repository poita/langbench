from cmarkpy.escaping import decode_entities, escape_html, href, unescape_string


def test_escape_html():
    assert escape_html("a&b<c>d\"e'f") == "a&amp;b&lt;c&gt;d&quot;e'f"


def test_decode_entities():
    assert decode_entities("&amp;&#35;&#X41;&#xD800;&bogus;") == "&#A�&bogus;"


def test_unescape_order():
    assert unescape_string("\\&amp;") == "&"
    assert unescape_string("&#92;*") == "*"


def test_href_encoding():
    assert href("/a b\"<>[]\\^`{|}é") == "/a%20b%22%3C%3E%5B%5D%5C%5E%60%7B%7C%7D%C3%A9"
    assert href("a&b'c%20") == "a&amp;b&#x27;c%20"


def test_href_blocked_schemes():
    for d in ("javascript:x", "JAVASCRIPT:x", "vbscript:x", "file:///x", "data:text/html,x"):
        assert href(d) == ""
    assert href("data:image/GIF;base64,x") == "data:image/GIF;base64,x"
