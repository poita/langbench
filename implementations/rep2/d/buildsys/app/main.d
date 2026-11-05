/**
 * Command-line driver: `buildsys <input directory> <output directory>`.
 *
 * Replays `<input>/session.txt` against the workspace in `<input>` and writes
 * `log.txt` and the final `workspace/` into the output directory.
 */
module main;

import kiln;

import std.file : exists, mkdirRecurse, read, write;
import std.path : buildPath;
import std.stdio : stderr;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: buildsys <input directory> <output directory>");
        return 2;
    }
    immutable inDir = args[1];
    immutable outDir = args[2];

    auto vfs = new Vfs;
    vfs.loadFrom(inDir, "session.txt");
    immutable sessionPath = buildPath(inDir, "session.txt");
    string script = exists(sessionPath) ? cast(string) read(sessionPath) : "";

    immutable log = runSession(vfs, parseSession(script));

    mkdirRecurse(outDir);
    write(buildPath(outDir, "log.txt"), log);
    vfs.saveTo(buildPath(outDir, "workspace"));
    return 0;
}
