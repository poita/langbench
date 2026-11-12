from mimedump import Kind, parse_message


def msg(*lines, crlf=False):
    sep = b"\r\n" if crlf else b"\n"
    return parse_message(sep.join(lines))


def test_default_type_and_leaf():
    m = msg(b"Subject: x", b"", b"hello")
    root = m.root
    assert (root.content_type, root.charset, root.encoding, root.kind) == (
        "text/plain", "us-ascii", "7bit", Kind.LEAF)
    assert root.content == b"hello"
    assert m.text_part is root and m.html_part is None and m.attachments == []


def test_multipart_structure_preamble_epilogue():
    m = msg(
        b"Content-Type: multipart/mixed; boundary=B", b"",
        b"pre", b"--B", b"", b"one", b"--B  ", b"", b"two", b"--B--", b"epi", b"",
    )
    root = m.root
    assert root.kind is Kind.MULTIPART and root.boundary == "B"
    assert root.preamble == b"pre" and root.epilogue == b"epi\n"
    assert [p.content for p in root.children] == [b"one", b"two"]
    assert [p.index for p in m.parts] == [0, 1, 2]


def test_no_close_delimiter_and_no_delimiter():
    m = msg(b"Content-Type: multipart/mixed; boundary=B", b"", b"--B", b"", b"one", b"")
    assert m.root.epilogue is None and m.root.children[0].content == b"one"
    m = msg(b"Content-Type: multipart/mixed; boundary=B", b"", b"just text")
    assert m.root.children == [] and m.root.preamble == b"just text"


def test_adjacent_delimiters_make_empty_part():
    m = msg(b"Content-Type: multipart/mixed; boundary=B", b"", b"--B", b"--B", b"--B--")
    assert len(m.root.children) == 2
    assert m.root.children[0].content == b""


def test_multipart_without_boundary_is_leaf():
    m = msg(b"Content-Type: multipart/mixed", b"", b"x")
    assert m.root.kind is Kind.LEAF


def test_digest_default_type_and_rfc822_container():
    m = msg(
        b"Content-Type: multipart/digest; boundary=D", b"",
        b"--D", b"", b"Subject: inner", b"", b"body", b"--D--",
    )
    inner = m.parts[1]
    assert inner.content_type == "message/rfc822" and inner.kind is Kind.MESSAGE
    assert inner.children[0].content == b"body"
    assert m.text_part is None  # not descended into the message container
    assert [p.index for p in m.attachments] == [2]  # but its leaves are attachments


def test_message_other_is_leaf():
    m = msg(b"Content-Type: message/delivery-status", b"", b"x")
    assert m.root.kind is Kind.LEAF


def test_crlf_is_normalised_and_size_is_original():
    raw = b"Content-Type: text/plain\r\n\r\na\r\nb\r\n"
    m = parse_message(raw)
    assert m.root.content == b"a\nb\n" and m.size == len(raw)


def test_body_selection_rules():
    m = msg(
        b"Content-Type: multipart/mixed; boundary=B", b"",
        b"--B", b"Content-Disposition: attachment", b"", b"a",
        b"--B", b"Content-Type: text/html", b"", b"<p>", 
        b"--B", b"Content-Type: text/plain", b"Content-Disposition: inline", b"", b"t",
        b"--B", b"Content-Type: text/plain", b"", b"t2", b"--B--",
    )
    assert m.text_part.index == 3 and m.html_part.index == 2
    assert [p.index for p in m.attachments] == [1, 4]


def test_filename_sources():
    m = msg(b"Content-Type: text/plain; name=ct.txt", b"", b"x")
    assert m.root.filename == "ct.txt"
    m = msg(b"Content-Type: text/plain; name=ct.txt", b"Content-Disposition: inline; filename=cd.txt", b"", b"x")
    assert m.root.filename == "cd.txt" and m.root.disposition == "inline"
    m = msg(b"Content-Disposition: ", b"", b"x")
    assert m.root.disposition == "inline"


def test_transfer_decoding_and_charset():
    m = msg(
        b"Content-Type: text/plain; charset=ISO-8859-1",
        b"Content-Transfer-Encoding: Quoted-Printable", b"", b"caf=E9",
    )
    assert m.root.encoding == "quoted-printable" and m.root.text == "café"


def test_bad_content_type_falls_back_to_default_but_keeps_params():
    m = msg(b"Content-Type: nonsense; charset=utf-8", b"", b"x")
    assert m.root.content_type == "text/plain" and m.root.charset == "utf-8"


def test_boundary_with_blanks_and_multibyte():
    m = msg(b'Content-Type: multipart/mixed; boundary="a b \xc3\xa9"', b"", b"--a b \xc3\xa9", b"", b"x", b"--a b \xc3\xa9--")
    assert len(m.root.children) == 1
