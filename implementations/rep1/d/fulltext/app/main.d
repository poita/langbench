/// Command-line front end: `fulltext <input directory> <output directory>`.
module app.main;

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
    immutable inputDir = args[1], outputDir = args[2];

    auto index = Index.build(loadDocuments(inputDir));
    auto queries = parseQueryFile(readText(buildPath(inputDir, "queries.txt")));

    if (!exists(outputDir))
        mkdirRecurse(outputDir);
    write(buildPath(outputDir, "results.txt"), renderResults(new Searcher(index), queries));
    write(buildPath(outputDir, "stats.txt"), renderStats(index));
    return 0;
}
