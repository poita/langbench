/// Command-line front end: reads a request on stdin, prints one verdict per test.
module app;

import core.thread : Thread;
import std.stdio : stderr, stdin, stdout;

import jsonschema;

private string readAll()
{
    import core.stdc.stdio : fread, stdin;

    ubyte[] buf = new ubyte[1 << 20];
    size_t len = 0;
    for (;;)
    {
        if (len == buf.length)
            buf.length = buf.length * 2;
        immutable n = fread(buf.ptr + len, 1, buf.length - len, stdin);
        if (n == 0)
            break;
        len += n;
    }
    return cast(string) buf[0 .. len];
}

int main()
{
    int status = 0;
    string result;
    string error;

    void work()
    {
        try
            result = processRequest(readAll());
        catch (Exception e)
        {
            error = e.msg;
            status = 1;
        }
    }

    // Evaluation is recursive and schemas can nest deeply: use a big stack.
    auto t = new Thread(&work, 1024UL * 1024 * 1024);
    t.start();
    t.join();

    if (status != 0)
    {
        stderr.writeln("jsonschema: ", error);
        return status;
    }
    stdout.rawWrite(result);
    return 0;
}
