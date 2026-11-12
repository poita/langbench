# qrcode

A QR Code Model 2 (ISO/IEC 18004) encoder written in D, using only Phobos. It
is a reusable library (`source/qrcode/`) plus a thin command-line tool
(`cli/app.d`) that reads encoding queries on stdin and prints each symbol's
module matrix as text.

Supported: versions 1-40, error correction levels L/M/Q/H, numeric,
alphanumeric and byte modes (single segment, no ECI), fixed masks 0-7 or
automatic mask selection by the standard penalty rules (N1-N4).

## Build

Requires LDC and dub (developed with LDC 1.41.0 and dub 1.40.0).

    dub build -b release --compiler=ldc2      # or ./build.sh

This builds the `application` configuration and produces the `qrcode`
executable in the project root. `./run.sh` runs it from any directory.

## Test

    dub test --compiler=ldc2

The tests are D `unittest` blocks next to the code they exercise, including the
worked examples of the specification.

## Command-line use

Each line of stdin is a query, `<ecl> <mask> <text>`:

* `<ecl>`: `L`, `M`, `Q` or `H`
* `<mask>`: `0`..`7`, or `auto` to choose by penalty score (ties: lowest mask)
* `<text>`: the rest of the line, taken as raw UTF-8 bytes

For each query the tool prints `version <v> mask <m>`, then `4v+17` rows of `#`
(dark) and `.` (light) with no quiet zone, then an empty line.

    $ echo "L auto 01234567" | ./run.sh
    version 1 mask 3
    #######.##..#.#######
    ...

The exit status is 0 on success; 1 for a malformed query or a payload that
fits in no version.

## Library use

```d
import qrcode;
import std.stdio;

void main()
{
    // Mask chosen automatically; pass 0..7 as the third argument to force one.
    QrCode qr = encodeText("HELLO WORLD", Ecl.medium);
    writeln("version ", qr.ver, ", mask ", qr.mask, ", size ", qr.size);

    foreach (y; 0 .. qr.size)
    {
        foreach (x; 0 .. qr.size)
            write(qr.isDark(x, y) ? "██" : "  ");
        writeln();
    }

    writeln(qr.toText()); // same format as the command-line tool
}
```

`encode(const(ubyte)[] data, Ecl ecl, int mask = autoMask)` is the byte-level
entry point; both throw `DataTooLongException` if the payload does not fit.

### Modules

| module               | responsibility                                        |
|----------------------|-------------------------------------------------------|
| `qrcode.tables`      | capacity, block and alignment tables, `Ecl`            |
| `qrcode.bitbuffer`   | MSB-first bit accumulator                              |
| `qrcode.segment`     | mode and version selection, data bit stream, padding   |
| `qrcode.reedsolomon` | GF(2^8) arithmetic, generator polynomial, ECC          |
| `qrcode.matrix`      | function patterns, zigzag placement, masks, format info|
| `qrcode.penalty`     | mask penalty rules N1-N4                               |
| `qrcode.encoder`     | `encode`, `QrCode`, block interleaving                 |
| `qrcode.query`       | parsing/rendering of the CLI query format              |

`import qrcode;` re-exports all of them.

To use the library without the CLI, depend on the package and select the
`library` configuration.
