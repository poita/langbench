/// The `kiln` command-line tool: `kiln <input dir> <output dir>`.
module app;

import std.file : exists, isDir, mkdirRecurse, write;
import std.path : buildPath;
import std.stdio : stderr;
import kiln.fsio;
import kiln.session;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: kiln <input directory> <output directory>");
        return 2;
    }
    immutable inDir = args[1];
    immutable outDir = args[2];
    if (!exists(inDir) || !isDir(inDir))
    {
        stderr.writeln("kiln: not a directory: ", inDir);
        return 2;
    }
    auto input = loadInput(inDir);
    auto log = runSession(input.workspace, input.sessionText);
    mkdirRecurse(outDir);
    write(buildPath(outDir, "log.txt"), log);
    writeWorkspace(input.workspace, outDir);
    return 0;
}
