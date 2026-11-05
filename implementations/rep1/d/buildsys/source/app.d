/// Command-line front end: `kiln <input directory> <output directory>`.
module app;

import std.stdio : stderr;

import kiln.fsio;
import kiln.session;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: ", args[0], " <input directory> <output directory>");
        return 2;
    }
    try
    {
        auto s = loadInput(args[1]);
        const log = runSession(s.vfs, s.script);
        writeOutput(args[2], log, s.vfs);
    }
    catch (Exception e)
    {
        stderr.writeln("kiln: ", e.msg);
        return 1;
    }
    return 0;
}
