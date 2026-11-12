/**
 * Command-line front end: reads operation lines on stdin and writes one
 * 8-digit hex result per line on stdout.
 *
 * See SPEC.md for the format.  Exit status is 0 on success, 1 on malformed
 * input or I/O failure (with a message on stderr).
 */
module app.main;

import std.stdio : stderr, stdin, stdout;

import softfloat.text : ParseException, processInput;

int main(string[] args)
{
    if (args.length > 1 && (args[1] == "-h" || args[1] == "--help"))
    {
        stdout.writeln("usage: softfloat < ops.txt > results.txt\n"
                ~ "Reads lines `<op> <a> [<b>]` (op: add sub mul div sqrt; operands: 8 hex digits)\n"
                ~ "and prints the binary32 result bit pattern of each as 8 hex digits.");
        return 0;
    }

    try
    {
        auto input = readAll();
        stdout.rawWrite(processInput(cast(const(char)[]) input));
        stdout.flush();
    }
    catch (ParseException e)
    {
        stderr.writefln("softfloat: line %s: %s", e.line, e.msg);
        return 1;
    }
    catch (Exception e)
    {
        stderr.writefln("softfloat: %s", e.msg);
        return 1;
    }
    return 0;
}

private ubyte[] readAll()
{
    import std.array : appender;

    auto data = appender!(ubyte[]);
    foreach (chunk; stdin.byChunk(1 << 16))
        data.put(chunk);
    return data[];
}
