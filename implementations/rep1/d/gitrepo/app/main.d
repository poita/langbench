/// Command-line entry point: `gitrepo <input path> <output dir>`.
module main;

import std.stdio : stderr;

import gitrepo.batch : runBatch;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: gitrepo <input path> <output dir>");
        return 2;
    }
    try
        runBatch(args[1], args[2]);
    catch (Exception e)
    {
        stderr.writeln("gitrepo: ", e.msg);
        return 1;
    }
    return 0;
}
