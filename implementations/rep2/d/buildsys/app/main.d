/**
 * The `kiln` command-line tool.
 *
 * Usage: `kiln <input directory> <output directory>`
 *
 * Loads the workspace and `session.txt` from the input directory, runs the
 * session, and writes `log.txt` and the final `workspace/` tree into the
 * output directory.
 */
module app.main;

import kiln;
import std.file : exists, mkdirRecurse, read, write;
import std.path : buildPath;
import std.stdio : stderr;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: ", args[0], " <input directory> <output directory>");
        return 2;
    }
    immutable inputDir = args[1], outputDir = args[2];
    immutable sessionPath = buildPath(inputDir, "session.txt");
    if (!exists(sessionPath))
    {
        stderr.writeln("kiln: no session.txt in ", inputDir);
        return 2;
    }

    auto ws = loadWorkspace(inputDir);
    auto sessionText = cast(string) read(sessionPath);
    auto log = runSession(ws, sessionText);

    mkdirRecurse(outputDir);
    write(buildPath(outputDir, "log.txt"), log);
    writeWorkspace(ws, outputDir);
    return 0;
}
