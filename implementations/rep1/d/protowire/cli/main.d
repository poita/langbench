/// protowire command-line tool: schema and requests on stdin, results on stdout.
module main;

import core.stdc.stdio : fread, fwrite, stdin, stdout, fflush;

import protowire.memory : ByteBuffer;
import protowire.session : processDocument;

int main()
{
    ByteBuffer input;
    for (;;)
    {
        input.reserve(1 << 16);
        const n = fread(input.tail, 1, 1 << 16, stdin);
        if (n == 0)
            break;
        input.advance(n);
    }

    ByteBuffer output;
    processDocument(input.data, output);
    if (output.length)
        fwrite(output.data.ptr, 1, output.length, stdout);
    fflush(stdout);
    return 0;
}
