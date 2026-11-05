/// Command-line front end: `kvstore <input dir> <output dir>`.
///
/// Reads `commands.txt` (and optionally `main.tdb` / `main.twal`) from the
/// input directory, runs the script and writes `results.txt`, `main.tdb` and
/// `main.twal` into the output directory.
module main;

import std.file : exists, isFile, mkdirRecurse, read, write;
import std.path : buildPath;
import std.stdio : stderr;

import tessera;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: kvstore <input dir> <output dir>");
        return 2;
    }
    immutable inDir = args[1];
    immutable outDir = args[2];

    ubyte[] slurp(string name)
    {
        immutable p = buildPath(inDir, name);
        return exists(p) && isFile(p) ? cast(ubyte[]) read(p) : null;
    }

    auto script = slurp("commands.txt");
    auto db = new Database(slurp("main.tdb"), slurp("main.twal"));
    auto interp = new Interpreter(db);
    interp.runScript(cast(const(char)[]) script);

    mkdirRecurse(outDir);
    write(buildPath(outDir, "results.txt"), interp.output);
    write(buildPath(outDir, "main.tdb"), db.databaseBytes);
    write(buildPath(outDir, "main.twal"), db.logBytes);
    return 0;
}
