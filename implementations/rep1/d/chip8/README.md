# chip8

A small, deterministic CHIP-8 interpreter written in D, split into a reusable
library and a thin command-line tool. The exact semantics (shifts, `FX55`/`FX65`,
`BNNN`, sprite wrapping, timer rate, RNG) are defined by the problem's `SPEC.md`.

The interpreter is a plain fetch–decode–execute loop: one `switch` on the top
nibble per cycle, hot registers kept in locals, the display stored as 32 `ulong`
rows so a sprite row is one rotate, one AND and one XOR. Nothing is pre-decoded,
so self-modifying code works.

## Layout

| Path | Contents |
|------|----------|
| `source/chip8/constants.d` | memory/display dimensions, font data |
| `source/chip8/display.d`   | `Display`: bit-packed 64×32 screen, sprite XOR, text rendering |
| `source/chip8/rng.d`       | the LCG used by `CXNN` |
| `source/chip8/machine.d`   | `Machine`, `KeyEvent` and the interpreter loop (`Machine.run`) |
| `source/chip8/input.d`     | `parseProgram` for the textual input format |
| `source/chip8/output.d`    | `formatState`: the 34-line output |
| `source/chip8/package.d`   | `import chip8;` re-exports everything |
| `app/main.d`               | the command-line tool |
| `tests/`                   | unit tests (separate from the library) |

## Build

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh          # dub build -b release --compiler=ldc2 → bin/chip8
dub test --compiler=ldc2   # unit tests
```

## Command-line usage

`./run.sh` (or `bin/chip8`) reads the program on stdin and writes the final
state to stdout. Input is three lines:

```
<rom-hex>            ROM bytes, lowercase hex, loaded at 0x200
<cycles>             number of cycles to execute (0..4000000000)
<key-schedule>       optional: "<cycle>:<mask4hex>" events separated by spaces
```

Output is 32 display rows of `#`/`.`, then `PC=… I=… SP=… DT=… ST=…` and
`V=` with the 16 registers.

```console
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Malformed input prints a message to stderr and exits with status 1.

## Library example

Add the package to a dub project (`dependency "chip8" path="../chip8"` with the
`library` configuration, e.g. `subConfiguration "chip8" "library"`), then:

```d
import chip8;

void main()
{
    // V0 = 5, V1 = 3, V2 = 0xA; I = glyph 'A'; draw it at (V0, V1); spin.
    ubyte[] rom = [0x60, 0x05, 0x61, 0x03, 0x62, 0x0a, 0xf2, 0x29,
                   0xd0, 0x15, 0x12, 0x0a];
    Machine m;
    m.reset();                 // font + PC = 0x200
    m.loadRom(rom);

    // Hold key 3 from cycle 100 on.
    m.run(1000, [KeyEvent(100, 1 << 3)]);

    import std.stdio : write;
    write(m.display.render()); // 32 lines of '#' / '.'
    assert(m.pc == 0x20a);
}
```

`Machine.run` may be called repeatedly; cycle numbers in key events are absolute.
`parseProgram` and `formatState` implement the CLI's text formats if you want
them in your own tools.
