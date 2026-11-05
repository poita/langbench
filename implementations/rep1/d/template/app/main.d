/// Command-line front end: reads a document from stdin (JSON context, `--`,
/// then `=== name` templates), renders the first template and prints the
/// result, or a single `error: <kind>` line.
module main;

import core.stdc.stdio : fread, fwrite, stdin, stdout, fflush;
import core.memory : GC;

import jtemplate.document : renderDocument;

private string readAllStdin() @trusted
{
    char[] buf = cast(char[]) GC.malloc(1 << 20, GC.BlkAttr.NO_SCAN)[0 .. 1 << 20];
    size_t len = 0;
    for (;;)
    {
        if (len == buf.length)
        {
            auto bigger = cast(char*) GC.malloc(buf.length * 2, GC.BlkAttr.NO_SCAN);
            bigger[0 .. len] = buf[0 .. len];
            buf = bigger[0 .. buf.length * 2];
        }
        immutable n = fread(buf.ptr + len, 1, buf.length - len, stdin);
        if (n == 0) break;
        len += n;
    }
    return cast(string) buf[0 .. len];
}

int main()
{
    auto output = renderDocument(readAllStdin());
    (() @trusted {
        fwrite(output.ptr, 1, output.length, stdout);
        fflush(stdout);
    })();
    return 0;
}
