/**
 * Loading a corpus from disk: `<input>/docs/<id>.txt`.
 */
module fulltext.corpus;

import fulltext.index : Document;

/**
 * Reads every regular file whose name ends in `.txt` directly inside
 * `<inputDir>/docs`. The id is the file name without the extension. A missing
 * `docs` directory gives an empty corpus. The result is sorted by id.
 */
Document[] loadDocuments(string inputDir) @trusted
{
    import std.algorithm : endsWith, sort;
    import std.file : DirEntry, SpanMode, dirEntries, exists, isDir, read;
    import std.path : baseName, buildPath;

    immutable dir = buildPath(inputDir, "docs");
    Document[] docs;
    if (!exists(dir) || !isDir(dir))
        return docs;
    foreach (DirEntry e; dirEntries(dir, SpanMode.shallow))
    {
        immutable name = baseName(e.name);
        if (!e.isFile || !name.endsWith(".txt"))
            continue;
        docs ~= Document(name[0 .. $ - 4], cast(string) read(e.name));
    }
    docs.sort!((a, b) => a.id < b.id);
    return docs;
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    immutable root = buildPath(tempDir, "fulltext-corpus-test");
    scope (exit) rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "docs", "sub.txt"));
    write(buildPath(root, "docs", "b.txt"), "second");
    write(buildPath(root, "docs", "a.txt"), "first");
    write(buildPath(root, "docs", "ignored.md"), "no");

    auto docs = loadDocuments(root);
    assert(docs.length == 2);
    assert(docs[0] == Document("a", "first"));
    assert(docs[1] == Document("b", "second"));
    assert(loadDocuments(buildPath(root, "missing")).length == 0);
}
