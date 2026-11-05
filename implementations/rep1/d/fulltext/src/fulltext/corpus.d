/**
 * Reading a corpus from disk.
 */
module fulltext.corpus;

import std.algorithm.searching : endsWith;
import std.file : DirEntry, SpanMode, dirEntries, exists, isDir, read;
import std.path : baseName, buildPath;

import fulltext.index : Document;

/**
 * Loads every regular file named `*.txt` directly inside `<inputDir>/docs`.
 * A missing `docs` directory yields no documents. The id of a document is
 * its file name without the `.txt` suffix.
 */
Document[] loadDocuments(string inputDir)
{
    Document[] docs;
    immutable dir = buildPath(inputDir, "docs");
    if (!exists(dir) || !isDir(dir))
        return docs;
    foreach (DirEntry e; dirEntries(dir, SpanMode.shallow))
    {
        auto name = baseName(e.name);
        if (!e.isFile || !name.endsWith(".txt"))
            continue;
        auto bytes = cast(immutable(ubyte)[]) read(e.name);
        docs ~= Document(name[0 .. $ - 4], bytes);
    }
    return docs;
}
