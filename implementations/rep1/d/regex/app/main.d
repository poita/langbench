/// Command-line front end: reads the batch format on stdin, writes results to stdout.
module main;

import core.stdc.stdio : fread, fwrite, stderr, stdin, stdout, fprintf;
import btregex;

int main()
{
    ubyte[] data = new ubyte[1 << 20];
    size_t used = 0;
    while (true)
    {
        if (used == data.length)
            data.length = data.length * 2;
        const n = fread(data.ptr + used, 1, data.length - used, stdin);
        if (n == 0)
            break;
        used += n;
    }

    try
    {
        runBatch(data[0 .. used], (const(ubyte)[] chunk) {
            fwrite(chunk.ptr, 1, chunk.length, stdout);
        });
    }
    catch (Exception e)
    {
        fprintf(stderr, "btregex: %.*s\n", cast(int) e.msg.length, e.msg.ptr);
        return 1;
    }
    return 0;
}
