/// Command-line tool: `sqlitefile <input directory> <output directory>`.
///
/// The input directory holds one `*.sqlite` database and a `queries.txt`; the
/// result of the n-th query line is written to `NNN.txt` in the output directory.
module app;

import std.file : dirEntries, exists, isFile, read, SpanMode, write;
import std.format : format;
import std.path : baseName, buildPath;
import std.stdio : stderr;
import sqlitefile;

private immutable errorOutput = cast(immutable(ubyte)[]) "error\n";

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: sqlitefile <input directory> <output directory>");
        return 2;
    }
    const inputDir = args[1], outputDir = args[2];

    string dbPath;
    foreach (e; dirEntries(inputDir, SpanMode.shallow))
        if (e.isFile && e.name.length > 7 && e.name[$ - 7 .. $] == ".sqlite")
        {
            dbPath = e.name;
            break;
        }
    const queriesPath = buildPath(inputDir, "queries.txt");
    if (dbPath.length == 0 || !exists(queriesPath))
    {
        stderr.writeln("sqlitefile: input directory needs a .sqlite file and queries.txt");
        return 2;
    }

    const text = cast(string) read(queriesPath);
    string[] lines;
    size_t start = 0;
    foreach (i, c; text)
        if (c == '\n')
        {
            lines ~= text[start .. i];
            start = i + 1;
        }
    if (start < text.length)
        lines ~= text[start .. $];

    Engine engine;
    try
        engine = new Engine(Database.open(dbPath));
    catch (Exception e)
        stderr.writeln("sqlitefile: cannot read database: ", e.msg);

    foreach (n, line; lines)
    {
        const(ubyte)[] result = engine is null ? errorOutput : engine.executeOrError(line);
        write(buildPath(outputDir, format("%03d.txt", n + 1)), result);
    }
    return 0;
}
