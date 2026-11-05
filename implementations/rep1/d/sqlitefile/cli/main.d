/// Command-line front end: `sqlitefile <input dir> <output dir>`.
///
/// The input directory holds one `*.sqlite` database and a `queries.txt`
/// with one query per line; line n's result is written to `<output dir>/NNN.txt`.
module main;

import std.file : DirEntry, dirEntries, exists, readText, SpanMode, write;
import std.format : format;
import std.path : baseName, buildPath, extension;
import std.stdio : stderr;
import std.array : split;
import sqlitefile;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: sqlitefile <input dir> <output dir>");
        return 2;
    }
    try
    {
        run(args[1], args[2]);
    }
    catch (Exception e)
    {
        stderr.writeln("sqlitefile: ", e.msg);
        return 1;
    }
    return 0;
}

private string findDatabase(string dir)
{
    foreach (DirEntry e; dirEntries(dir, SpanMode.shallow))
        if (e.isFile && extension(e.name) == ".sqlite")
            return e.name;
    throw new Exception("no .sqlite file in " ~ dir);
}

private string[] readQueries(string path)
{
    // Split on LF only: lineSplitter would also break on U+2028 and friends.
    auto lines = readText(path).split('\n');
    if (lines.length && lines[$ - 1].length == 0)
        lines = lines[0 .. $ - 1];
    return lines;
}

private void run(string inputDir, string outputDir)
{
    auto lines = readQueries(buildPath(inputDir, "queries.txt"));
    Database db;
    Catalog cat;
    try
    {
        db = Database.open(findDatabase(inputDir));
        cat = Catalog.load(db);
    }
    catch (Exception e)
    {
        stderr.writeln("sqlitefile: cannot read database: ", e.msg);
    }
    foreach (i, line; lines)
    {
        immutable(ubyte)[] result = db is null ? cast(immutable(ubyte)[]) "error\n" : answer(db, cat, line);
        write(buildPath(outputDir, format("%03d.txt", i + 1)), result);
    }
}
