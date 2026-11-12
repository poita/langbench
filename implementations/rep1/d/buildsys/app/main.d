/// Command-line front end: `kiln <input directory> <output directory>`.
module app.main;

import std.file : mkdirRecurse, read, write;
import std.path : buildPath;
import std.stdio : stderr;

import kiln;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: ", args[0], " <input directory> <output directory>");
        return 2;
    }
    const inDir = args[1];
    const outDir = args[2];
    try
    {
        auto fs = loadWorkspace(inDir);
        const steps = parseSession(cast(string) read(buildPath(inDir, sessionFileName)));
        const log = runSession(fs, steps);
        mkdirRecurse(outDir);
        write(buildPath(outDir, "log.txt"), log);
        writeWorkspace(fs, outDir);
    }
    catch (Exception e)
    {
        stderr.writeln("kiln: ", e.msg);
        return 1;
    }
    return 0;
}

