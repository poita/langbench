/// Command-line front end: reads a command script on stdin, prints answers on stdout.
module main;

import std.stdio : stdin, stdout;
import orderedmap;

/// Reads all of standard input into one buffer.
char[] readAll()
{
    char[] data = new char[1 << 20];
    size_t n = 0;
    while (true)
    {
        if (n == data.length)
            data.length = data.length * 2;
        auto got = stdin.rawRead(data[n .. $]);
        if (got.length == 0)
            break;
        n += got.length;
    }
    return data[0 .. n];
}

int main()
{
    auto input = readAll();
    const q = commandCount(input);
    auto map = OrderedMap(q + 1);
    auto output = OutBuffer(1 << 20);
    runScript(input, map, output);
    stdout.rawWrite(output.data);
    stdout.flush();
    return 0;
}
