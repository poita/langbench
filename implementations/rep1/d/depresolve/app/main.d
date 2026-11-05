/// Command-line front end: reads the registry and root manifest on stdin,
/// writes the resolution (or `unsatisfiable`) on stdout.
module main;

import std.stdio : stdin, stdout;
import depresolve;

int main()
{
    ubyte[] data;
    foreach (chunk; stdin.byChunk(1 << 16))
        data ~= chunk;
    auto reg = parseRegistry(cast(const(char)[]) data);
    const res = resolve(reg);
    stdout.rawWrite(formatResolution(res));
    stdout.flush();
    return 0;
}
