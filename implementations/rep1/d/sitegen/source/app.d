/**
 * The sitegen command-line tool.
 *
 * Usage: `sitegen <input directory> <output directory>`
 */
module app;

import std.stdio : stderr;
import sitegen.generator : generateSite;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: sitegen <input directory> <output directory>");
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
