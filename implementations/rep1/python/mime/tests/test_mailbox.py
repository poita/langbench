from mimedump.mailbox import read_mailbox, split_mbox


def test_split_basic():
    data = b"junk\n\nFrom a\nS: 1\n\nbody\n\nFrom b\nS: 2\n\n"
    assert split_mbox(data) == [b"S: 1\n\nbody\n", b"S: 2\n"]


def test_no_separator_means_no_messages():
    assert split_mbox(b"hello\nFrom x\n") == []


def test_from_line_needs_preceding_empty_line():
    data = b"From a\nx\nFrom not a separator\ny\n"
    assert split_mbox(data) == [b"x\nFrom not a separator\ny\n"]


def test_crlf_empty_line_counts_and_double_lf_rule_is_literal():
    data = b"From a\r\nx\r\n\r\nFrom b\r\ny\r\n"
    assert split_mbox(data) == [b"x\r\n\r\n", b"y\r\n"]


def test_separator_at_eof_gives_empty_message():
    assert split_mbox(b"From a") == [b""]
    assert split_mbox(b"From a\n\nFrom b\n") == [b"\n", b""]


def test_directory_listing(tmp_path):
    for name, data in [("b.eml", b"B"), ("Z.eml", b"Z"), ("a.EML", b"x"), ("c.txt", b"x")]:
        (tmp_path / name).write_bytes(data)
    (tmp_path / "sub.eml").mkdir()
    got = read_mailbox(str(tmp_path))
    assert [(m.source_id, m.data) for m in got] == [("Z.eml", b"Z"), ("b.eml", b"B")]


def test_mbox_source_ids(tmp_path):
    p = tmp_path / "box"
    p.write_bytes(b"From a\nA\n\nFrom b\nB\n")
    assert [m.source_id for m in read_mailbox(str(p))] == ["mbox:1", "mbox:2"]
