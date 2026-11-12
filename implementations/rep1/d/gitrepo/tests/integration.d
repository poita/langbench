/// End-to-end tests: build small repositories on disk and run the commands.
module integration;

import std.algorithm : canFind;
import std.exception : assertThrown;
import std.file : exists, readText, write;
import std.path : buildPath;

import fixture;
import gitrepo.batch;
import gitrepo.commands;
import gitrepo.errors;
import gitrepo.objectid;
import gitrepo.repository;

private string run(Repository r, string line)
{
    return cast(string) execute(r, line);
}

/// A history of two commits plus an annotated tag, with a mix of loose and
/// packed objects (an OFS_DELTA and a REF_DELTA whose base is loose).
private struct World
{
    TempRepo t;
    ObjectId blobA, blobA2, blobB, tree1, tree2, subtree, c1, c2, tag;
}

private World buildWorld(string name)
{
    World w;
    w.t = TempRepo.create(name);
    auto t = &w.t;
    const a = bytes("alpha line one\n");
    const a2 = a ~ bytes("and two\n");
    const b = a ~ bytes("beta\n");
    w.blobA = t.loose("blob", a);

    PackBuilder pb;
    pb.add(3, "blob", bytes("pack only\n"));
    immutable a2Offset = pb.add(3, "blob", a2);
    w.blobA2 = objectId("blob", a2);
    // An OFS_DELTA against a plain packed object...
    pb.addOfsDelta(a2Offset, appendDelta(a2, bytes("y")), objectId("blob", a2 ~ bytes("y")));
    // ...and a REF_DELTA whose base is a loose object.
    w.blobB = objectId("blob", b);
    pb.addRefDelta(w.blobA, appendDelta(a, bytes("beta\n")), w.blobB);
    pb.finish(t.repo, "pack-test");

    w.subtree = t.loose("tree", treePayload([Entry("100644", "b.txt", w.blobB)]));
    w.tree1 = t.loose("tree", treePayload([Entry("100644", "a.txt", w.blobA)]));
    w.tree2 = t.loose("tree", treePayload([
            Entry("100644", "a.txt", w.blobA2), Entry("40000", "dir", w.subtree),
            Entry("100644", "caf\xc3\xa9.txt", w.blobA)
        ]));
    immutable who = " Ada Lovelace <ada@example.org> ";
    w.c1 = t.loose("commit", bytes("tree " ~ w.tree1.toString ~ "\nauthor" ~ who ~ "1400000000 +0000\ncommitter" ~ who
            ~ "1400000000 +0000\n\nFirst   \ncommit\n\nbody\n"));
    w.c2 = t.loose("commit", bytes("tree " ~ w.tree2.toString ~ "\nparent " ~ w.c1.toString ~ "\nauthor" ~ who
            ~ "1400003600 +0000\ncommitter" ~ who ~ "1400003600 +0000\n\nSecond\n"));
    w.tag = t.loose("tag", bytes("object " ~ w.c2.toString ~ "\ntype commit\ntag v1\ntagger" ~ who
            ~ "1400003600 +0000\n\nrelease\n"));
    t.writeRef("HEAD", "ref: refs/heads/main\n");
    t.writeRef("refs/heads/main", w.c2.toString ~ "\n");
    t.writeRef("packed-refs", "# pack-refs with: peeled fully-peeled sorted\n" ~ w.tag.toString
            ~ " refs/tags/v1\n^" ~ w.c2.toString ~ "\n" ~ w.c1.toString ~ " refs/heads/old\n");
    return w;
}

unittest
{
    auto w = buildWorld("world-basic");
    scope (exit)
        w.t.remove();
    auto r = new Repository(w.t.repo);

    assert(run(r, "count-objects") == "loose: 7\nin-pack: 4\npacks: 1\n");
    assert(run(r, "rev-parse HEAD") == w.c2.toString ~ "\n");
    assert(run(r, "rev-parse main^") == w.c1.toString ~ "\n");
    assert(run(r, "rev-parse main~1") == w.c1.toString ~ "\n");
    assert(run(r, "rev-parse HEAD^0") == w.c2.toString ~ "\n");
    assert(run(r, "rev-parse v1") == w.tag.toString ~ "\n");
    assert(run(r, "rev-parse v1^{}") == w.c2.toString ~ "\n");
    assert(run(r, "rev-parse v1^{commit}") == w.c2.toString ~ "\n");
    assert(run(r, "rev-parse v1^{tree}") == w.tree2.toString ~ "\n");
    assert(run(r, "rev-parse old") == w.c1.toString ~ "\n");
    assert(run(r, "rev-parse " ~ w.c1.toString[0 .. 8]) == w.c1.toString ~ "\n");
    assert(run(r, "rev-parse HEAD^{object}") == w.c2.toString ~ "\n");
    foreach (bad; [
            "rev-parse HEAD^2", "rev-parse HEAD~2", "rev-parse config", "rev-parse HEAD^{blob}",
            "rev-parse HEAD^{bogus}", "rev-parse", "rev-parse  HEAD", "rev-parse HEAD ", "rev-parse abc",
            "rev-parse 0000000000000000000000000000000000000000", "frobnicate", "COUNT-OBJECTS",
            "count-objects x", "log", "ls-tree HEAD a.txt", "ls-tree HEAD dir/", "ls-tree HEAD /dir",
            "ls-tree HEAD dir//x", "ls-tree HEAD .", "ls-tree HEAD nosuch", "ls-tree HEAD ",
            "ls-tree v1^{blob}", "log HEAD x", "log HEAD -1", "log HEAD ", "cat-file nosuch",
            "diff HEAD", "diff HEAD HEAD^{blob}",
        ])
        assertThrown!GitError(execute(r, bad), bad);
}

unittest
{
    auto w = buildWorld("world-commands");
    scope (exit)
        w.t.remove();
    auto r = new Repository(w.t.repo);

    immutable expectedLog = w.c2.toString ~ " Ada Lovelace 1400003600 Second\n" ~ w.c1.toString
        ~ " Ada Lovelace 1400000000 First commit\n";
    assert(run(r, "log HEAD") == expectedLog);
    assert(run(r, "log v1") == expectedLog);
    assert(run(r, "log HEAD 1") == w.c2.toString ~ " Ada Lovelace 1400003600 Second\n");
    assert(run(r, "log HEAD 0") == "");
    assert(run(r, "log HEAD 99") == expectedLog);

    assert(run(r, "ls-tree HEAD") == "100644 blob " ~ w.blobA2.toString ~ "\ta.txt\n040000 tree "
            ~ w.subtree.toString ~ "\tdir\n100644 blob " ~ w.blobA.toString ~ "\t\"caf\\303\\251.txt\"\n");
    assert(run(r, "ls-tree HEAD dir") == "100644 blob " ~ w.blobB.toString ~ "\tb.txt\n");
    assert(run(r, "ls-tree " ~ w.tree1.toString) == "100644 blob " ~ w.blobA.toString ~ "\ta.txt\n");

    immutable zero = "0000000000000000000000000000000000000000";
    // Sorted by raw path bytes: "a.txt" < "caf\303\251.txt" < "dir/b.txt".
    assert(run(r, "diff HEAD^ HEAD") == ":100644 100644 " ~ w.blobA.toString ~ " " ~ w.blobA2.toString
            ~ " M\ta.txt\n:000000 100644 " ~ zero ~ " " ~ w.blobA.toString ~ " A\t\"caf\\303\\251.txt\"\n"
            ~ ":000000 100644 " ~ zero ~ " " ~ w.blobB.toString ~ " A\tdir/b.txt\n");
    assert(run(r, "diff HEAD HEAD") == "");
    assert(run(r, "diff HEAD^ HEAD").length == run(r, "diff old main").length);
    assert(run(r, "diff main main^").canFind(" D\tdir/b.txt\n"));

    // cat-file verifies the hash; payloads come back verbatim, including deltas.
    assert(run(r, "cat-file " ~ w.blobA.toString) == "blob 15\nalpha line one\n");
    assert(run(r, "cat-file " ~ w.blobB.toString) == "blob 20\nalpha line one\nbeta\n");
    immutable tagText = run(r, "cat-file v1");
    assert(tagText[0 .. 4] == "tag " && tagText.canFind("\nobject " ~ w.c2.toString ~ "\n"));
    assert(run(r, "cat-file " ~ w.blobA2.toString[0 .. 10]) == "blob 23\nalpha line one\nand two\n");
    assert(run(r, "cat-file HEAD^{tree}")[0 .. 5] == "tree ");
}

unittest
{
    // A damaged loose object makes only the commands that read it fail.
    auto w = buildWorld("world-damaged");
    scope (exit)
        w.t.remove();
    immutable hex = w.blobA.toString;
    write(buildPath(w.t.repo, "objects", hex[0 .. 2], hex[2 .. $]), zlibStored(bytes("blob 3\0toolong")));
    auto r = new Repository(w.t.repo);
    assertThrown!GitError(execute(r, "cat-file " ~ hex));
    assertThrown!GitError(execute(r, "cat-file " ~ w.blobB.toString)); // REF_DELTA with a damaged base
    assert(run(r, "rev-parse " ~ hex) == hex ~ "\n"); // resolving never reads content
    assert(run(r, "rev-parse " ~ hex ~ "^{object}") == hex ~ "\n");
    assert(run(r, "log HEAD 1").length > 0);
    assert(run(r, "count-objects").canFind("loose: 7"));
}

unittest
{
    // Content that does not match its id fails cat-file but not rev-parse.
    auto t = TempRepo.create("world-wrongid");
    scope (exit)
        t.remove();
    immutable id = t.loose("blob", bytes("real\n"));
    immutable hex = id.toString;
    write(buildPath(t.repo, "objects", hex[0 .. 2], hex[2 .. $]), zlibStored(bytes("blob 5\0fake\n")));
    auto r = new Repository(t.repo);
    assertThrown!GitError(execute(r, "cat-file " ~ hex));
    assert(run(r, "rev-parse " ~ hex) == hex ~ "\n");
}

unittest
{
    // Ambiguous abbreviations fail; loose + packed copies of one id count once.
    auto t = TempRepo.create("world-abbrev");
    scope (exit)
        t.remove();
    ObjectId[] ids;
    foreach (i; 0 .. 40)
        ids ~= t.loose("blob", bytes("blob number " ~ cast(char)('a' + i % 26) ~ cast(char)('A' + i / 26) ~ "\n"));
    PackBuilder pb;
    pb.add(3, "blob", bytes("blob number aA\n")); // same object as ids[0]
    pb.finish(t.repo, "pack-dup");
    auto r = new Repository(t.repo);
    assert(run(r, "count-objects") == "loose: 40\nin-pack: 1\npacks: 1\n");
    assert(run(r, "rev-parse " ~ ids[0].toString[0 .. 6]) == ids[0].toString ~ "\n");
    assert(run(r, "rev-parse " ~ ids[0].toString[0 .. 6].dup.toUpper) == ids[0].toString ~ "\n");
    // Find a prefix shared by two objects, if any, and check that it fails.
    foreach (i; 0 .. ids.length)
        foreach (j; i + 1 .. ids.length)
            if (ids[i].toString[0 .. 4] == ids[j].toString[0 .. 4])
                assertThrown!GitError(execute(r, "rev-parse " ~ ids[i].toString[0 .. 4]));
    // The first byte is shared by several of 40 random ids: 3 hex digits are too short anyway.
    assertThrown!GitError(execute(r, "rev-parse " ~ ids[0].toString[0 .. 3]));
}

private string toUpper(char[] s)
{
    foreach (ref c; s)
        if (c >= 'a' && c <= 'f')
            c -= 32;
    return s.idup;
}

unittest
{
    // The batch driver: one file per line, `error` for failures, no blank-line tricks.
    auto w = buildWorld("world-batch");
    scope (exit)
        w.t.remove();
    write(buildPath(w.t.root, "commands.txt"), "rev-parse HEAD\nbogus\ncount-objects");
    immutable outDir = buildPath(w.t.root, "out");
    runBatch(w.t.root, outDir);
    assert(readText(buildPath(outDir, "001.out")) == w.c2.toString ~ "\n");
    assert(readText(buildPath(outDir, "002.out")) == "error\n");
    assert(readText(buildPath(outDir, "003.out")).canFind("packs: 1"));
    assert(!exists(buildPath(outDir, "004.out")));
}

unittest
{
    // An empty repository still answers.
    auto t = TempRepo.create("world-empty");
    scope (exit)
        t.remove();
    write(buildPath(t.repo, "HEAD"), "ref: refs/heads/main\n");
    auto r = new Repository(t.repo);
    assert(run(r, "count-objects") == "loose: 0\nin-pack: 0\npacks: 0\n");
    assertThrown!GitError(execute(r, "rev-parse HEAD"));
    assertThrown!GitError(execute(r, "log HEAD"));
}
