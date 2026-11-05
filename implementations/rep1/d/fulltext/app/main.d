/// Command-line front end: `fulltext <input directory> <output directory>`.
module main;

import std.array : appender;
import std.file : exists, mkdirRecurse, readText, write;
import std.path : buildPath;
import std.stdio : stderr;

import fulltext;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: fulltext <input directory> <output directory>");
        return 2;
    }
    immutable inputDir = args[1];
    immutable outputDir = args[2];

    auto index = new Index(loadDocuments(inputDir));
    auto engine = new SearchEngine(index);
    auto queries = parseQueryFile(cast(string) readBytes(buildPath(inputDir, "queries.txt")));

    auto results = appender!string;
    foreach (q; queries)
        formatQueryBlock(results, q.number, q.text, engine.search(q.text, q.k));

    if (!exists(outputDir))
        mkdirRecurse(outputDir);
    write(buildPath(outputDir, "results.txt"), results.data);
    write(buildPath(outputDir, "stats.txt"), formatStats(index));
    return 0;
}

private immutable(ubyte)[] readBytes(string path)
{
    import std.file : read;

    return cast(immutable(ubyte)[]) read(path);
}
