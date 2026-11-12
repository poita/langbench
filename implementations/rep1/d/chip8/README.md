# chip8

A deterministic CHIP-8 interpreter written in D, as a reusable library plus a
thin command-line tool. It follows a fully specified variant of the classic
semantics (fixed shift/`FX55`/`BNNN`/wrapping behaviour, a specified LCG, timers
ticking every 8 cycles), so the same input always yields the same output.

Every cycle the opcode is fetched from memory and decoded afresh; there is no
pre-decoding or caching, so self-modifying programs work.

## Build

Requires LDC and dub (tested with LDC 1.41.0 and dub 1.40.0).

```sh
./build.sh            # dub build -b release --compiler=ldc2 :cli  ->  bin/chip8
dub test --compiler=ldc2   # run the unit tests
```

## Command-line use

`./run.sh` (or `bin/chip8`) reads a job on stdin and writes a report to stdout.
Input is three lines: the ROM as lowercase hex, the cycle count, and an
optional key schedule of `<cycle>:<mask>` events (mask = four hex digits, bit
`k` = key `k` held).

```sh
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Output is 32 display rows of 64 `#`/`.` characters, a `PC=… I=… SP=… DT=… ST=…`
line, and a `V=` line with the 16 registers. Malformed input gives a message
on stderr and exit status 1.

## Library

Source modules (`import chip8;` pulls in all of them):

| Module | Responsibility |
|--------|----------------|
| `chip8.font` | built-in font data and glyph addresses |
| `chip8.rng` | the specified 32-bit LCG |
| `chip8.display` | 64x32 XOR framebuffer with wrap-around |
| `chip8.machine` | CPU state and `Machine.step` |
| `chip8.input` | parsing the job format (`Job`, `KeyEvent`) |
| `chip8.runner` | `run`: the cycle loop with key schedule |
| `chip8.output` | `report`: formatting the final state |
| `chip8.program` | `simulate`: parse + run + format |

Example:

```d
import chip8;
import std.stdio;

void main()
{
    // V0 = 5; I = font glyph for V0; draw it at (V1, V2) = (0, 0).
    ubyte[] rom = [0x60, 0x05, 0xF0, 0x29, 0xD1, 0x25, 0x12, 0x06];
    auto m = Machine(rom);
    run(m, 100, [KeyEvent(10, 0x0001)]);   // key 0 pressed before cycle 10
    writeln(m.display.render());
    writefln("PC=%04x V0=%02x", m.pc, m.v[0]);

    // Or the whole text pipeline in one call:
    write(simulate("60ff7001610180141208\n6\n"));
}
```

## Layout

```
dub.sdl            library package "chip8" (sub-package :cli)
source/chip8/      library modules, each with unittest blocks
cli/               command-line tool (cli/source/app.d)
build.sh run.sh    build and run wrappers
```
