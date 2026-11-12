/// Command-line front end: `typeset <input dir> <output dir>`.
module app.main;

import std.file : exists, mkdirRecurse, write;
import std.path : buildPath;
import std.stdio : stderr;

import typeset;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: typeset <input directory> <output directory>");
        return 2;
    }
    immutable inputDir = args[1], outputDir = args[2];
    if (!exists(outputDir))
        mkdirRecurse(outputDir);

    Resources resources;
    try
        resources = Resources.load("data");
    catch (Exception e)
    {
        stderr.writeln("typeset: cannot load data/: ", e.msg);
        return 1;
    }

    auto result = typesetDirectory(resources, inputDir);
    if (result.ok)
    {
        write(buildPath(outputDir, "layout.txt"), result.layout.toText());
        write(buildPath(outputDir, "report.txt"), result.report.toText());
    }
    else
        write(buildPath(outputDir, "error.txt"), result.errorText());
    return 0;
}
