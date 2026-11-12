from gitrepo.objects import entry_type, parse_commit, parse_ident, parse_tree, subject_of
from gitrepo.quoting import quote_path


def test_subject():
    assert subject_of(b"\n\nFix the thing   \nand the other\n\nbody\n") == b"Fix the thing and the other"
    assert subject_of(b"") == b""
    assert subject_of(b" \t\n\n") == b""
    assert subject_of(b"one\r\ntwo\x0b\n") == b"one two"


def test_ident():
    assert parse_ident(b"Ada L  <a@b> 1400003600 +0100") == (b"Ada L", 1400003600)
    assert parse_ident(b"X <a@b>") == (b"X", 0)
    assert parse_ident(b"X <a@b>   -77 +0000") == (b"X", 77)
    assert parse_ident(b"no brackets") == (b"no brackets", 0)
    assert parse_ident(b"<a@b> 5") == (b"", 5)


def test_commit_headers():
    tree = "a" * 40
    p1, p2 = "b" * 40, "c" * 40
    payload = (b"tree " + tree.encode() + b"\nparent " + p1.encode() + b"\nparent " + p2.encode()
               + b"\nauthor A <a@x> 10 +0000\ngpgsig -----BEGIN\n parent " + b"d" * 40
               + b"\n -----END\ncommitter C <c@x> 20 +0000\nauthor B <b@x> 30 +0000\n\nSubj\n\nbody\n")
    c = parse_commit(payload)
    assert c.tree == tree and c.parents == (p1, p2)
    assert (c.author_name, c.author_time) == (b"B", 30)
    assert (c.committer_name, c.committer_time) == (b"C", 20)
    assert c.message == b"Subj\n\nbody\n" and c.subject == b"Subj"


def test_commit_without_message():
    assert parse_commit(b"tree " + b"a" * 40 + b"\n").message == b""


def test_tree_parse_and_types():
    raw = b"100644 a\0" + b"\x01" * 20 + b"40000 d\0" + b"\x02" * 20 + b"160000 s\0" + b"\x03" * 20
    entries = parse_tree(raw)
    assert [e.name for e in entries] == [b"a", b"d", b"s"]
    assert [e.type for e in entries] == ["blob", "tree", "commit"]
    assert entries[1].mode == 0o40000 and entries[0].id == "01" * 20
    assert entry_type(0o120000) == "blob"


def test_quote():
    assert quote_path(b"plain.txt") == b"plain.txt"
    assert quote_path("café.txt".encode()) == b'"caf\\303\\251.txt"'
    assert quote_path(b'quote"and\\slash.txt') == b'"quote\\"and\\\\slash.txt"'
    assert quote_path(b"a\tb\x01\x7f") == b'"a\\tb\\001\\177"'
    assert quote_path(b"") == b""
