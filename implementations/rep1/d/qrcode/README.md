# qrcode

A QR Code Model 2 (ISO/IEC 18004) encoder written in D, using only Phobos and
druntime. It is a small reusable library plus a thin command-line tool that
reads queries on stdin and prints each symbol as a `#`/`.` module matrix.

Features: numeric, alphanumeric and byte modes (chosen automatically),
versions 1–40, error correction levels L/M/Q/H, Reed-Solomon coding over
GF(2^8), all eight mask patterns, and automatic mask selection by the
standard N1–N4 penalty scoring.

## Layout

| Path                  | Contents                                           |
|-----------------------|----------------------------------------------------|
| `src/qrcode/`         | the library (`import qrcode;`)                     |
| `app/main.d`          | the command-line tool                              |
| `tests/`              | unit tests (separate from the library sources)     |
| `build.sh`, `run.sh`  | build and run helpers                              |

Library modules: `tables` (capacity tables), `segment` (mode/version
selection, data packing), `bitbuffer` (MSB-first bit writer), `gf`
(GF(2^8) and Reed-Solomon), `matrix` (function patterns, placement, masking),
`penalty` (mask scoring) and `encoder` (the public `encode` function).

## Building

Requires LDC and dub (developed with LDC 1.41.0 and dub 1.40.0).

    dub build -b release --compiler=ldc2    # or ./build.sh

This produces `bin/qrcode`. Run the unit tests with:

    dub test --compiler=ldc2

## Command-line usage

`./run.sh` (or `bin/qrcode`) reads all of stdin. Each line is

    <ecl> <mask> <text>

where `<ecl>` is `L`, `M`, `Q` or `H`, `<mask>` is `0`–`7` or `auto`, and
`<text>` is the rest of the line, treated as raw UTF-8 bytes. For each query
it prints

    version <v> mask <m>
    <size rows of # (dark) and . (light)>
    <empty line>

Example:

    $ echo "M auto HELLO WORLD" | ./run.sh
    version 1 mask 0
    #######...#.#.#######
    ...

Malformed input or text too long for version 40 prints a message on stderr
and exits with status 1.

## Library usage

```d
import std.stdio;
import qrcode;

void main()
{
    // Mode and version are chosen automatically; the mask is picked by
    // penalty scoring. Pass 0..7 as the third argument to force a mask.
    auto code = encode("HELLO WORLD", Ecl.M);

    writeln("version ", code.version_, ", mask ", code.mask, ", ", code.size, " modules");
    foreach (y; 0 .. code.size)
    {
        foreach (x; 0 .. code.size)
            write(code.isDark(x, y) ? "##" : "  ");
        writeln();
    }
    // code.toText() gives the same text format the CLI prints.
}
```

`encode` accepts either a `string` or a `const(ubyte)[]` payload and throws
`QrException` if the data does not fit in version 40 at the requested level.
To use the library from another dub project, add this package as a
dependency and select its `library` configuration.
