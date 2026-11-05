/// Unit tests for the repository, revision syntax, queries and pack reading.
module unit.test_repository;

import std.conv : to;
import std.exception : assertThrown;
import std.file : readText;
import std.algorithm.iteration : map;
import std.array : array;
import std.string : splitLines, toUpper;

import gitrepo;
import unit.fixture;

private string text(const(ubyte)[] b)
{
    return cast(string) b.idup;
}

/// loose history: c1 (a.txt) <- c2 (a.txt changed, dir/b.txt) <- c3 (merge-less, deletes a.txt)
private struct Hist
{
    Fixture fx;
    ObjectId b1, b2, b3, t1, t2, t3, c1, c2, c3;
}

private Hist makeHistory(string name)
{
    Hist h;
    h.fx = Fixture.create(name);
    auto fx = &h.fx;
    h.b1 = fx.blob("one\n");
    h.b2 = fx.blob("two\n");
    h.b3 = fx.blob("three\n");
    h.t1 = fx.tree([Entry("100644", "a.txt", h.b1)]);
    auto sub = fx.tree([Entry("100644", "b.txt", h.b3)]);
    h.t2 = fx.tree([Entry("100644", "a.txt", h.b2), Entry("40000", "dir", sub)]);
    h.t3 = fx.tree([Entry("40000", "dir", sub)]);
    h.c1 = fx.commit(h.t1, [], 1000, "first");
    h.c2 = fx.commit(h.t2, [h.c1], 2000, "second  \n\nbody");
    h.c3 = fx.commit(h.t3, [h.c2], 3000, "third");
    fx.write("refs/heads/main", h.c3.toString() ~ "\n");
    fx.write("refs/tags/v1", h.c1.toString() ~ "\n");
    fx.write("HEAD", "ref: refs/heads/main\n");
    return h;
}

unittest
{
    auto h = makeHistory("revparse");
    scope (exit) h.fx.destroy();
    auto repo = new Repository(h.fx.root);
    assert(repo.revParse("HEAD") == h.c3);
    assert(repo.revParse("main") == h.c3);
    assert(repo.revParse("heads/main") == h.c3);
    assert(repo.revParse("refs/heads/main") == h.c3);
    assert(repo.revParse("v1") == h.c1);
    assert(repo.revParse("main^") == h.c2);
    assert(repo.revParse("main~2") == h.c1);
    assert(repo.revParse("main^^") == h.c1);
    assert(repo.revParse("main~0") == h.c3);
    assert(repo.revParse("main^0") == h.c3);
    assert(repo.revParse("main^{tree}") == h.t3);
    assert(repo.revParse("main~1^{tree}") == h.t2);
    assert(repo.revParse("main^{commit}") == h.c3);
    assert(repo.revParse("main^{object}") == h.c3);
    assert(repo.revParse("main^{}") == h.c3);
    assert(repo.revParse(h.c2.toString()) == h.c2);
    assert(repo.revParse(h.c2.toString()[0 .. 8]) == h.c2);
    assert(repo.revParse(h.c2.toString()[0 .. 9]) == h.c2);
    assert(repo.revParse(h.c2.toString()[0 .. 8].toUpper) == h.c2);
    assertThrown!GitError(repo.revParse("main~3"));
    assertThrown!GitError(repo.revParse("main^2"));
    assertThrown!GitError(repo.revParse("main^{blob}"));
    assertThrown!GitError(repo.revParse("main^{nonsense}"));
    assertThrown!GitError(repo.revParse("nosuchname"));
    assertThrown!GitError(repo.revParse("config"));
    assertThrown!GitError(repo.revParse(""));
    assertThrown!GitError(repo.revParse("abc"));            // too short for an abbreviation
    assertThrown!GitError(repo.revParse("0000000000000000000000000000000000000000"));
}

unittest
{
    auto h = makeHistory("commands");
    scope (exit) h.fx.destroy();
    auto repo = new Repository(h.fx.root);

    assert(text(execute(repo, "count-objects")) == "loose: 10\nin-pack: 0\npacks: 0\n");
    assert(text(execute(repo, "rev-parse main~1")) == h.c2.toString() ~ "\n");

    auto log = splitLines(text(execute(repo, "log main")));
    assert(log.length == 3);
    assert(log[0] == h.c3.toString() ~ " Ada Lovelace 3000 third");
    assert(log[1] == h.c2.toString() ~ " Ada Lovelace 2000 second");
    assert(log[2] == h.c1.toString() ~ " Ada Lovelace 1000 first");
    assert(splitLines(text(execute(repo, "log main 2"))).length == 2);
    assert(execute(repo, "log main 0").length == 0);
    assertThrown!GitError(execute(repo, "log main x"));
    assertThrown!GitError(execute(repo, "log main  2"));
    assertThrown!GitError(execute(repo, "log main^{tree}"));

    assert(text(execute(repo, "ls-tree main~1")) ==
        "100644 blob " ~ h.b2.toString() ~ "\ta.txt\n" ~
        "040000 tree " ~ repo.tree(h.t2).entries[1].id.toString() ~ "\tdir\n");
    assert(text(execute(repo, "ls-tree main dir")) == "100644 blob " ~ h.b3.toString() ~ "\tb.txt\n");
    assertThrown!GitError(execute(repo, "ls-tree main "));
    assertThrown!GitError(execute(repo, "ls-tree main dir/"));
    assertThrown!GitError(execute(repo, "ls-tree main a.txt"));
    assertThrown!GitError(execute(repo, "ls-tree main nope"));

    assert(text(execute(repo, "cat-file " ~ h.b1.toString())) == "blob 4\none\n");
    assert(text(execute(repo, "cat-file main")).length > 100);

    immutable zeros = "0000000000000000000000000000000000000000";
    assert(text(execute(repo, "diff main~2 main~1")) ==
        ":100644 100644 " ~ h.b1.toString() ~ " " ~ h.b2.toString() ~ " M\ta.txt\n" ~
        ":000000 100644 " ~ zeros ~ " " ~ h.b3.toString() ~ " A\tdir/b.txt\n");
    assert(text(execute(repo, "diff main~1 main")) ==
        ":100644 000000 " ~ h.b2.toString() ~ " " ~ zeros ~ " D\ta.txt\n");
    assert(execute(repo, "diff main main").length == 0);

    assertThrown!GitError(execute(repo, "frobnicate"));
    assertThrown!GitError(execute(repo, "count-objects x"));
    assertThrown!GitError(execute(repo, "rev-parse"));
}

unittest
{
    // cat-file verifies the hash: a loose file holding the wrong object fails
    auto fx = Fixture.create("badhash");
    scope (exit) fx.destroy();
    auto good = fx.blob("good\n");
    auto other = idOf("blob", cast(const(ubyte)[]) "other\n");
    auto hex = other.toString();
    fx.write("objects/" ~ hex[0 .. 2] ~ "/" ~ hex[2 .. $], zlibStored(storedForm("blob", cast(const(ubyte)[]) "tampered\n")));
    auto repo = new Repository(fx.root);
    assert(text(execute(repo, "cat-file " ~ good.toString())) == "blob 5\ngood\n");
    assertThrown!GitError(execute(repo, "cat-file " ~ hex));
    // rev-parse does not read the object
    assert(text(execute(repo, "rev-parse " ~ hex)) == hex ~ "\n");
}

unittest
{
    // refs: packed-refs, symbolic chains, ref loops, and ref names that never resolve
    auto fx = Fixture.create("refs");
    scope (exit) fx.destroy();
    auto b = fx.blob("x");
    auto b2 = fx.blob("y");
    fx.write("packed-refs", "# pack-refs with: peeled\n" ~ b.toString() ~ " refs/tags/p\n^" ~ b2.toString() ~ "\n"
        ~ b2.toString() ~ " refs/heads/q\n");
    fx.write("refs/heads/q", b.toString() ~ "  \n");                   // loose wins over packed
    fx.write("refs/heads/s1", "ref: refs/heads/s2\n");
    fx.write("refs/heads/s2", "ref: refs/tags/p\n");
    fx.write("refs/heads/loop", "ref: refs/heads/loop\n");
    fx.write("config", b.toString() ~ "\n");
    auto repo = new Repository(fx.root);
    assert(repo.revParse("p") == b);
    assert(repo.revParse("q") == b);
    assert(repo.revParse("s1") == b);
    assertThrown!GitError(repo.revParse("loop"));
    assertThrown!GitError(repo.revParse("config"));
    assertThrown!GitError(repo.revParse("refs/heads/../heads/q"));
    assertThrown!GitError(repo.revParse("refs//tags/p"));
}

unittest
{
    // tags: peeling, ^{} and ^{commit}
    auto fx = Fixture.create("tags");
    scope (exit) fx.destroy();
    auto t = fx.tree([]);
    auto c = fx.commit(t, [], 5, "c");
    auto tag1 = fx.loose("tag", "object " ~ c.toString() ~ "\ntype commit\ntag t1\ntagger x <x> 1 +0000\n\nmsg\n");
    auto tag2 = fx.loose("tag", "object " ~ tag1.toString() ~ "\ntype tag\ntag t2\ntagger x <x> 1 +0000\n\nmsg\n");
    fx.write("refs/tags/t2", tag2.toString() ~ "\n");
    auto repo = new Repository(fx.root);
    assert(repo.revParse("t2") == tag2);
    assert(repo.revParse("t2^{}") == c);
    assert(repo.revParse("t2^{commit}") == c);
    assert(repo.revParse("t2^{tag}") == tag2);
    assert(repo.revParse("t2^{tree}") == t);
    assertThrown!GitError(repo.revParse("t2^2"));
    assert(repo.revParse("t2^0") == c);
    assertThrown!GitError(repo.revParse("t2^{blob}"));
    assert(text(execute(repo, "log t2")).length > 40);
    assert(text(execute(repo, "ls-tree t2")).length == 0);
}

unittest
{
    // log order: ties in committer date go to the commit discovered first
    auto fx = Fixture.create("logorder");
    scope (exit) fx.destroy();
    auto t = fx.tree([]);
    auto root = fx.commit(t, [], 10, "root");
    auto a = fx.commit(t, [root], 20, "a");
    auto b = fx.commit(t, [root], 20, "b");
    auto m = fx.commit(t, [a, b], 20, "merge");
    fx.write("refs/heads/main", m.toString() ~ "\n");
    auto repo = new Repository(fx.root);
    auto ids = repo.log(m).map!(e => e.id).array;
    assert(ids == [m, a, b, root]);
}

unittest
{
    // a pack with a plain blob and an OFS_DELTA on top of it, plus a REF_DELTA to a loose base
    auto fx = Fixture.create("pack");
    scope (exit) fx.destroy();
    immutable baseText = cast(immutable(ubyte)[]) "hello world";
    immutable targetText = cast(immutable(ubyte)[]) "hello, hello world!";
    ubyte[] delta = [11, 19, 7, 'h', 'e', 'l', 'l', 'o', ',', ' ', 0x90, 11, 1, '!'];

    ubyte[] pack = cast(ubyte[]) "PACK".dup;
    pack ~= [ubyte(0), 0, 0, 2, 0, 0, 0, 3];
    uint[] offsets;
    // object 1: blob (type 3), size 11
    offsets ~= cast(uint) pack.length;
    pack ~= cast(ubyte)(0x30 | 11);
    pack ~= zlibStored(baseText);
    // object 2: OFS_DELTA (type 6) against object 1
    offsets ~= cast(uint) pack.length;
    pack ~= cast(ubyte)(0x60 | delta.length);
    pack ~= cast(ubyte)(offsets[1] - offsets[0]);
    pack ~= zlibStored(delta);
    // object 3: REF_DELTA (type 7) against a loose blob
    auto looseBase = fx.blob("loose base");
    ubyte[] delta2 = [10, 11, 0x90, 10, 1, '!'];
    offsets ~= cast(uint) pack.length;
    pack ~= cast(ubyte)(0x70 | delta2.length);
    pack ~= looseBase.bytes[];
    pack ~= zlibStored(delta2);
    pack ~= new ubyte[20];

    auto baseId = idOf("blob", baseText);
    auto targetId = idOf("blob", targetText);
    auto thirdId = idOf("blob", cast(const(ubyte)[]) "loose base!");
    fx.write("objects/pack/pack-test.pack", pack);
    fx.write("objects/pack/pack-test.idx", makeIndex([baseId, targetId, thirdId], offsets));
    // an orphan index without a pack must be ignored
    fx.write("objects/pack/pack-orphan.idx", makeIndex([baseId], [12]));

    auto repo = new Repository(fx.root);
    assert(repo.store.packCount == 1);
    assert(repo.store.inPackCount == 3);
    assert(repo.store.looseCount == 1);
    auto o = repo.readObject(targetId);
    assert(o.type == ObjectType.blob && o.data == targetText);
    assert(text(execute(repo, "cat-file " ~ targetId.toString())) == "blob 19\nhello, hello world!");
    assert(text(execute(repo, "cat-file " ~ thirdId.toString())) == "blob 11\nloose base!");
    assert(repo.revParse(targetId.toString()[0 .. 10]) == targetId);
    assert(text(execute(repo, "count-objects")) == "loose: 1\nin-pack: 3\npacks: 1\n");
}
