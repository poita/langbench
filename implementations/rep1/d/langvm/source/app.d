/// Command-line tool: reads a Vellum module stream on stdin, compiles and runs
/// it, and writes the program's output (or a single diagnostic) to stdout.
module app;

import core.thread : Thread;
import std.array : appender;
import std.stdio : stderr, stdin, stdout;

import langvm;

/// Stack size of the interpreter thread: nested built-in callbacks recurse on the host stack.
enum stackSize = 256UL * 1024 * 1024;

int main()
{
    auto input = appender!(ubyte[])();
    foreach (chunk; stdin.byChunk(1 << 16))
        input.put(chunk);

    int status = 0;
    auto worker = new Thread({
        try
        {
            interpret(cast(const(char)[]) input.data, (const(char)[] s) {
                stdout.rawWrite(s);
            });
            stdout.flush();
        }
        catch (Throwable t)
        {
            stderr.writeln("internal error: ", t.toString());
            status = 70;
        }
    }, stackSize);
    worker.start();
    worker.join();
    return status;
}
