/// Command-line front end: `mime <input path> <output directory>`.
module app;

import std.stdio : stderr;

import mime.convert : convertMailbox;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: mime <input path> <output directory>");
        return 2;
    }
    try
    {
        convertMailbox(args[1], args[2]);
    }
    catch (Exception e)
    {
        stderr.writeln("mime: ", e.msg);
        return 1;
    }
    return 0;
}
