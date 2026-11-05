/// Command-line front end: `typeset [--data DIR] <input dir> <output dir>`.
module app;

import std.stdio : stderr;
import typeset.engine : typesetDirectory;

int main(string[] args)
{
    string dataDir = "data";
    string[] pos;
    for (size_t i = 1; i < args.length; ++i)
    {
        if (args[i] == "--data" && i + 1 < args.length)
            dataDir = args[++i];
        else
            pos ~= args[i];
    }
    if (pos.length != 2)
    {
        stderr.writeln("usage: typeset [--data DIR] <input directory> <output directory>");
        return 2;
    }
    try
    {
        typesetDirectory(pos[0], pos[1], dataDir);
    }
    catch (Exception e)
    {
        stderr.writeln("typeset: ", e.msg);
        return 1;
    }
    return 0;
}
