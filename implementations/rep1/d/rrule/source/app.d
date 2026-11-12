/// Command-line front end: reads `<DTSTART> <RRULE> <N>` lines on stdin and
/// prints the occurrences of each rule, one line per input line.
module app;

import std.array : Appender;
import std.stdio : File, stderr, stdin, stdout;

import rrule;

/// Flushes the output buffer to `f` once it grows beyond this size.
enum size_t flushThreshold = 1 << 20;

int main(string[] args)
{
    if (args.length > 1)
    {
        stderr.writeln("usage: rrule < rules.txt > occurrences.txt");
        return args[1] == "-h" || args[1] == "--help" ? 0 : 2;
    }
    Appender!(char[]) outBuf;
    int status = 0;
    size_t lineNo;
    foreach (line; stdin.byLine())
    {
        ++lineNo;
        try
        {
            const q = parseQuery(line);
            formatOccurrences(q, outBuf);
        }
        catch (ParseException e)
        {
            stderr.writefln("line %s: %s", lineNo, e.msg);
            status = 1;
        }
        outBuf.put('\n');
        if (outBuf[].length >= flushThreshold)
        {
            stdout.rawWrite(outBuf[]);
            outBuf.clear();
        }
    }
    stdout.rawWrite(outBuf[]);
    return status;
}
