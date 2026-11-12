from mimedump.headers import Header, find_header, parse_headers


def fields(data):
    headers, body = parse_headers(data)
    return [(h.name, h.value) for h in headers], body


def test_simple_and_folded():
    assert fields(b"A: 1\nB: x\n y\n\tz\n\nbody") == (
        [("A", " 1"), ("B", " x y\tz")],
        b"body",
    )


def test_block_ends_at_non_field_line():
    for line in (b"Subject :x", b"no colon here", b": novalue", b"From nobody Mon Sep  1 00:00:00 2025"):
        assert fields(b"A: 1\n" + line + b"\nrest") == ([("A", " 1")], line + b"\nrest")


def test_continuation_first_line_is_not_a_field():
    assert fields(b" x: 1\nA: 2\n") == ([], b" x: 1\nA: 2\n")


def test_headers_only_and_empty():
    assert fields(b"A: 1") == ([("A", " 1")], b"")
    assert fields(b"") == ([], b"")
    assert fields(b"\nbody") == ([], b"body")


def test_whitespace_only_line_is_a_continuation():
    assert fields(b"A: 1\n \nB: 2\n") == ([("A", " 1 "), ("B", " 2")], b"")


def test_display_value():
    assert Header("Content-Type", "  a   b\t c ").display_value == "a b c"
    assert Header("Subject", " =?utf-8?Q?a?=  ").display_value == "a"
    assert Header(" X-Y ", "").key == "x-y"


def test_find_header_first_wins_case_insensitive():
    headers, _ = parse_headers(b"X: 1\nx: 2\n")
    found = find_header(headers, "x")
    assert found is not None and found.value == " 1"
    assert find_header(headers, "y") is None


def test_invalid_utf8_in_headers_is_replaced():
    headers, _ = parse_headers(b"S: caf\xe9\n")
    assert headers[0].value == " caf�"
