/// Command-line front end: `mime <input mbox or directory> <output directory>`.
module app;

import std.stdio : stderr;
import mime.mailbox : readMailbox;
import mime.report : writeReport;

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: ", args.length ? args[0] : "mime", " <input mbox|directory> <output directory>");
        return 2;
    }
    try
    {
        writeReport(readMailbox(args[1]), args[2]);
    }
    catch (Exception e)
    {
        stderr.writeln("mime: ", e.msg);
        return 1;
    }
    return 0;
}
