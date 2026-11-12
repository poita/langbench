# chip8

A deterministic CHIP-8 interpreter written in D: a reusable library plus a thin
command-line tool. It follows a fully specified variant of the classic
semantics (in-place shifts, `BNNN` with `V0`, wrapping sprites, a timer tick
every 8 cycles, a specified LCG for `CXNN`), runs an exact number of cycles and
prints the display and CPU state. Every opcode is fetched and decoded from
memory on every cycle, so self-modifying programs work.

## Build

Requires LDC 1.41+ and dub 1.40+.

```sh
./build.sh          # same as: dub build -b release --compiler=ldc2
dub test --compiler=ldc2
```

This produces `bin/chip8`.

## Command-line usage

`chip8` takes no arguments. It reads three lines from stdin:

```
<rom-hex>          ROM bytes, lowercase hex (1..3584 bytes), loaded at 0x200
<cycles>           number of instruction cycles to run (0..4000000000)
<key-schedule>     optional: space-separated <cycle>:<mask> events, mask = 4 hex digits
```

and writes 34 lines to stdout: the 64x32 display (`#`/`.`), a
`PC=.. I=.. SP=.. DT=.. ST=..` line, and a `V=..` line with the 16 registers.
Malformed input exits with status 1 and a message on stderr.

```sh
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

## Library

Modules (all re-exported by `import chip8;`):

| Module | Responsibility |
|--------|----------------|
| `chip8.machine` | `Machine`: memory, registers, stack, timers, the interpreter loop |
| `chip8.display` | `Display`: 64x32 XOR frame buffer with wrap-around |
| `chip8.keys` | `KeySchedule`/`KeyEvent`: key state over time, O(1) per cycle |
| `chip8.rng` | `Lcg`: the specified 32-bit linear congruential generator |
| `chip8.font` | built-in font data and glyph addresses |
| `chip8.input` | `parseProgram`: the textual input format |
| `chip8.output` | `renderState`: the textual report |
| `chip8.cli` | `simulate`: the whole CLI as a `string -> string` function |

Example:

```d
import std.stdio;
import chip8;

void main()
{
    // V0 = 5; I = font glyph for V0; draw it at (V1, V2) = (0, 0).
    ubyte[] rom = [0x60, 0x05, 0xF0, 0x29, 0xD1, 0x25];
    auto machine = Machine(rom);
    auto keys = KeySchedule([KeyEvent(3, 0x0001)]); // key 0 held from cycle 3
    machine.run(3, keys);                           // run exactly 3 cycles

    write(renderState(machine));                    // display + registers
    writeln(machine.display[0, 0]);                 // true: glyph "5" starts with F0
}
```

To use it as a dependency, add `dependency "chip8" path="..."` to your
`dub.sdl`; dub selects the `library` configuration automatically.

## Tests

Unit tests are D `unittest` blocks next to the code they test (the spec's
worked examples are included); run them with `dub test --compiler=ldc2`.
The end-to-end suite is run from the repository root with
`python3 run_tests.py chip8 -- chip8/run.sh`.

## License

MIT
