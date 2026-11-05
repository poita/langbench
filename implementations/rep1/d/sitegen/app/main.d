/// Command-line front end: `sitegen <input directory> <output directory>`.
module main;

import sitegen.generator : generateSite;
import std.stdio : stderr;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: ", args.length ? args[0] : "sitegen", " <input directory> <output directory>");
        return 2;
    }
    try
    {
        generateSite(args[1], args[2]);
    }
    catch (Exception e)
    {
        stderr.writeln("sitegen: ", e.msg);
        return 1;
    }
    return 0;
}
