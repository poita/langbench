/// Command-line front end: reads one JSON document on stdin, prints
/// `valid` / `invalid` per test instance on stdout.
module app;

import core.thread : Thread;
import std.stdio : File, stderr, stdin, stdout;

import jsonschema;

private int exitCode;

private void run()
{
    ubyte[] data;
    ubyte[65536] buf;
    while (true)
    {
        auto got = stdin.rawRead(buf[]);
        if (got.length == 0)
            break;
        data ~= got;
    }
    try
    {
        auto lines = validateDocument(cast(const(char)[]) data);
        auto w = stdout.lockingBinaryWriter;
        foreach (l; lines)
        {
            w.put(l);
            w.put('\n');
        }
    }
    catch (Exception e)
    {
        stderr.writeln("error: ", e.msg);
        exitCode = 1;
    }
}

int main()
{
    // Schemas can nest hundreds of levels deep: evaluate on a big stack.
    auto t = new Thread(&run, 1024 * 1024 * 1024);
    t.start();
    t.join();
    return exitCode;
}
