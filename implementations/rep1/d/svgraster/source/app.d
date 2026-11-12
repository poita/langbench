/// Command-line front end: `svgraster <input-dir> <output-dir>`.
module app;

import std.stdio : stderr;
import svgraster.batch : renderDirectory;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writefln("usage: %s <input-dir> <output-dir>", args.length ? args[0] : "svgraster");
        return 2;
    }
    try
    {
        immutable failures = renderDirectory(args[1], args[2], (string m) {
            stderr.writeln("error: ", m);
        });
        return failures == 0 ? 0 : 1;
    }
    catch (Exception e)
    {
        stderr.writeln("error: ", e.msg);
        return 1;
    }
}
