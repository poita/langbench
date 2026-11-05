/// Command-line tool: reads a Vellum module stream on stdin, runs it, prints the result.
module main;

import core.thread : Thread, ThreadError;
import langvm;
import std.stdio : stdin, stdout;

/// Reads all of stdin.
private string readAllStdin()
{
    ubyte[] data;
    ubyte[1 << 16] buf;
    while (true)
    {
        auto got = stdin.rawRead(buf[]);
        if (got.length == 0)
            break;
        data ~= got;
    }
    return cast(string) data;
}

int main()
{
    string input = readAllStdin();
    string result;
    // Run on a thread with a large stack: the checker and parser recurse on nested syntax.
    void work()
    {
        result = runSource(input).stdout;
    }

    bool done = false;
    foreach (mb; [512, 128, 32])
    {
        try
        {
            auto t = new Thread(&work, mb * 1024 * 1024);
            t.start();
            t.join();
            done = true;
            break;
        }
        catch (ThreadError)
        {
            // could not reserve that much stack; try a smaller one
        }
    }
    if (!done)
        work();
    stdout.rawWrite(result);
    stdout.flush();
    return 0;
}
