/// Command-line front end: `tessera <input dir> <output dir>`.
///
/// Reads `commands.txt` (and optionally `main.tdb` and `main.twal`) from the
/// input directory, runs the script and writes `results.txt`, `main.tdb` and
/// `main.twal` into the output directory (SPEC §2).
module app;

import std.file : exists, isFile, mkdirRecurse, read, write;
import std.path : buildPath;
import std.stdio : stderr;

import tessera.engine : Engine;

private const(ubyte)[] readOptional(string path)
{
    return exists(path) && isFile(path) ? cast(const(ubyte)[]) read(path) : null;
}

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: tessera <input dir> <output dir>");
        return 2;
    }
    immutable inDir = args[1], outDir = args[2];

    immutable script = cast(string) read(buildPath(inDir, "commands.txt"));
    auto engine = new Engine(readOptional(buildPath(inDir, "main.tdb")),
            readOptional(buildPath(inDir, "main.twal")));
    immutable results = engine.runScript(script);
    engine.finish();

    mkdirRecurse(outDir);
    write(buildPath(outDir, "results.txt"), results);
    write(buildPath(outDir, "main.tdb"), engine.databaseImage);
    write(buildPath(outDir, "main.twal"), engine.logImage);
    return 0;
}
