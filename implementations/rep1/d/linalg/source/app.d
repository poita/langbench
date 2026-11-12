/// Command-line driver: `linalg <input directory> <output directory>`.
module app;

import std.stdio : stderr;

import linalg.script : runScript;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: linalg <input directory> <output directory>");
        return 2;
    }
    try
    {
        runScript(args[1], args[2]);
    }
    catch (Exception e)
    {
        stderr.writeln("linalg: ", e.msg);
        return 1;
    }
    return 0;
}
