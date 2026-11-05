/// Command-line front end: `svgraster <input-dir> <output-dir>`.
module main;

import std.stdio : stderr;
import svgraster.batch : renderDirectory;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: ", args.length ? args[0] : "svgraster", " <input-dir> <output-dir>");
        return 2;
    }
    try
    {
        auto failed = renderDirectory(args[1], args[2]);
        foreach (name; failed)
            stderr.writeln("svgraster: cannot read ", name);
        return failed.length ? 1 : 0;
    }
    catch (Exception e)
    {
        stderr.writeln("svgraster: ", e.msg);
        return 1;
    }
}
