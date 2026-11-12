import hashlib
import zlib

import pytest

from conftest import make_delta, oid_of
from gitrepo import Repository, run_command
from gitrepo.cli import run
from gitrepo.errors import RevisionError

ERR = b"error\n"


@pytest.fixture
def history(builder):
    b = builder
    f1 = b.blob(b"one file\n")
    f2 = b.blob(b"two\n")
    sub = b.tree([(b"100644", b"x.txt", f2)])
    t1 = b.tree([(b"100644", b"a.txt", f1)])
    t2 = b.tree([(b"100644", b"a.txt", f1), (b"40000", b"dir", sub), (b"120000", b"ln", f2)])
    c1 = b.commit(t1, when=100, msg=b"first\n")
    c2 = b.commit(t2, [c1], when=200, msg=b"\nsecond  \nline\n\nbody\n")
    tag = b.tag(c2)
    b.ref("refs/heads/main", c2)
    b.ref("refs/tags/v1", tag)
    b.ref("refs/heads/v1", c1)
    b.ref("HEAD", "ref: refs/heads/main")
    return dict(b=b, f1=f1, t1=t1, t2=t2, c1=c1, c2=c2, tag=tag, sub=sub, repo=Repository(b.git))


def test_rev_parse(history):
    h, r = history, history["repo"]
    assert r.rev_parse(b"HEAD") == h["c2"]
    assert r.rev_parse(b"main^") == h["c1"]
    assert r.rev_parse(b"main~1") == h["c1"]
    assert r.rev_parse(b"main^0") == h["c2"]
    assert r.rev_parse(b"v1") == h["tag"]          # refs/tags before refs/heads
    assert r.rev_parse(b"heads/v1") == h["c1"]
    assert r.rev_parse(b"v1^{}") == h["c2"]
    assert r.rev_parse(b"v1^{tree}") == h["t2"]
    assert r.rev_parse(b"v1^{tag}") == h["tag"]
    assert r.rev_parse(b"v1~1^{tree}") == h["t1"]
    assert r.rev_parse(h["c1"][:6].upper().encode()) == h["c1"]
    assert r.rev_parse(h["c1"].encode() + b"^{object}") == h["c1"]
    for bad in [b"main~2", b"main^2", b"main^{blob}", b"main^{wat}", b"zzzz", b"abc",
                b"config", b"refs/heads/", b"main^{", b"^{}", b"~1", b"HEAD..", b"0" * 40]:
        with pytest.raises(RevisionError):
            r.rev_parse(bad)


def test_ambiguous_prefix(builder):
    ids = [builder.blob(b"blob %d" % i) for i in range(1500)]
    r = Repository(builder.git)
    prefixes = {}
    for oid in ids:
        prefixes.setdefault(oid[:4], []).append(oid)
    unique = next(v[0] for v in prefixes.values() if len(v) == 1)
    assert r.rev_parse(unique[:4].encode()) == unique
    shared = next(k for k, v in prefixes.items() if len(v) > 1)  # ~17 expected
    assert run_command(r, b"rev-parse " + shared.encode()) == ERR
    assert run_command(r, b"rev-parse " + unique[:3].encode()) in (ERR, unique.encode() + b"\n")


def test_commands(history):
    h, r = history, history["repo"]
    run = lambda line: run_command(r, line)
    assert run(b"count-objects") == b"loose: 8\nin-pack: 0\npacks: 0\n"
    assert run(b"rev-parse HEAD") == h["c2"].encode() + b"\n"
    log = run(b"log HEAD").decode().splitlines()
    assert log == [f"{h['c2']} Ada 200 second line", f"{h['c1']} Ada 100 first"]
    assert run(b"log HEAD 1").decode().splitlines() == log[:1]
    assert run(b"log HEAD 0") == b""
    assert run(b"log HEAD x") == ERR and run(b"log HEAD -1") == ERR
    assert run(b"log " + h["f1"].encode()) == ERR
    ls = run(b"ls-tree HEAD").decode().splitlines()
    assert ls[1] == f"040000 tree {h['sub']}\tdir"
    assert ls[2].startswith("120000 blob ")
    assert run(b"ls-tree HEAD dir") == f"100644 blob {oid_of(b'blob', b'two' + chr(10).encode())}\tx.txt\n".encode()
    for bad in [b"ls-tree HEAD a.txt", b"ls-tree HEAD nope", b"ls-tree HEAD dir/", b"ls-tree HEAD /dir",
                b"ls-tree HEAD .", b"ls-tree HEAD ", b"ls-tree  HEAD", b"ls-tree HEAD dir//x"]:
        assert run(bad) == ERR
    assert run(b"cat-file " + h["f1"].encode()) == b"blob 9\none file\n"
    two = oid_of(b"blob", b"two\n")
    assert run(b"diff main~1 main").decode().splitlines() == [
        f":000000 100644 {'0' * 40} {two} A\tdir/x.txt",
        f":000000 120000 {'0' * 40} {two} A\tln",
    ]
    assert run(b"diff main main~1").decode().splitlines()[0].endswith("D\tdir/x.txt")
    assert run(b"diff main main") == b""
    assert run(b"frobnicate") == ERR and run(b"") == ERR and run(b"CAT-FILE x") == ERR
    assert run(b"rev-parse") == ERR and run(b"count-objects x") == ERR


def test_cat_file_detects_damage(builder):
    oid = builder.blob(b"hello")
    other = builder.blob(b"other")
    p = builder.git / "objects" / oid[:2] / oid[2:]
    q = builder.git / "objects" / other[:2] / other[2:]
    p.write_bytes(q.read_bytes())  # right zlib stream, wrong name
    r = Repository(builder.git)
    assert run_command(r, b"cat-file " + oid.encode()) == ERR
    assert run_command(r, oid.encode() + b"") == ERR
    assert run_command(r, b"rev-parse " + oid.encode()) == oid.encode() + b"\n"
    assert run_command(r, b"rev-parse " + oid.encode() + b"^{object}") == oid.encode() + b"\n"
    p.write_bytes(b"not zlib at all")
    r = Repository(builder.git)
    assert run_command(r, b"cat-file " + oid.encode()) == ERR


def test_packed_objects_and_deltas(builder):
    base = b"line\n" * 200
    mod = base + b"extra\n"
    third = mod + b"more\n"
    base_id, mod_id, third_id = (oid_of(b"blob", x) for x in (base, mod, third))
    offs = builder.write_pack("p1", [
        (b"blob", base),
        ("ofs", 0, make_delta(base, mod)),
        ("ofs", 1, make_delta(mod, third)),
    ])
    builder.write_index("p1", list(zip([base_id, mod_id, third_id], offs)))
    other = b"unrelated\n"
    other_id = oid_of(b"blob", other)
    ref_target = oid_of(b"blob", other + b"x")
    offs2 = builder.write_pack("p2", [(b"blob", other), ("ref", other_id, make_delta(other, other + b"x"))])
    builder.write_index("p2", list(zip([other_id, ref_target], offs2)))
    r = Repository(builder.git)
    assert run_command(r, b"count-objects") == b"loose: 0\nin-pack: 5\npacks: 2\n"
    for oid, data in [(base_id, base), (mod_id, mod), (third_id, third), (other_id, other),
                      (ref_target, other + b"x")]:
        assert run_command(r, b"cat-file " + oid.encode()) == b"blob %d\n" % len(data) + data
    assert run_command(r, b"rev-parse " + third_id[:7].encode()) == third_id.encode() + b"\n"


def test_loose_preferred_and_pack_without_idx_ignored(builder):
    oid = builder.blob(b"loose copy")
    builder.write_pack("lonely", [(b"blob", b"other")])
    r = Repository(builder.git)
    assert run_command(r, b"count-objects") == b"loose: 1\nin-pack: 0\npacks: 0\n"
    assert run_command(r, b"cat-file " + oid.encode()).endswith(b"loose copy")


def test_packed_refs_and_symref_depth(builder):
    c = builder.commit(builder.tree([]))
    (builder.git / "packed-refs").write_text(
        f"# pack-refs with: peeled\n{c} refs/heads/packed\n^{'0' * 40}\n{'1' * 40} refs/tags/dangling\n")
    builder.ref("HEAD", "ref: refs/heads/packed")
    for i in range(1, 7):
        builder.ref(f"refs/s{i}", f"ref: refs/s{i + 1}")
    builder.ref("refs/s7", c)
    r = Repository(builder.git)
    assert r.rev_parse(b"HEAD") == c
    assert r.rev_parse(b"packed") == c
    assert r.rev_parse(b"dangling") == "1" * 40          # refs are taken at face value
    assert r.rev_parse(b"refs/s2") == c                   # five follows is fine
    with pytest.raises(RevisionError):
        r.rev_parse(b"refs/s1")                           # six is too many
    with pytest.raises(RevisionError):
        r.rev_parse(b"dangling^{object}")


def test_log_order_ties_and_merge(builder):
    t = builder.tree([])
    root = builder.commit(t, when=10, msg=b"root\n")
    a = builder.commit(t, [root], when=50, msg=b"a\n")
    b2 = builder.commit(t, [root], when=50, msg=b"b\n")
    c = builder.commit(t, [root], when=50, msg=b"c\n")
    m = builder.commit(t, [a, b2, c], when=60, msg=b"m\n")
    builder.ref("refs/heads/main", m)
    r = Repository(builder.git)
    out = run_command(r, b"log main").decode().splitlines()
    assert [line.split()[0] for line in out] == [m, a, b2, c, root]


def test_cli(history, tmp_path):
    b = history["b"]
    b.commands("rev-parse HEAD", "count-objects", "bogus", "log HEAD 1")
    out = tmp_path / "out"
    run(str(b.root), str(out))
    assert sorted(p.name for p in out.iterdir()) == ["001.out", "002.out", "003.out", "004.out"]
    assert (out / "001.out").read_text() == history["c2"] + "\n"
    assert (out / "003.out").read_bytes() == ERR
