# chip8

A small, deterministic CHIP-8 interpreter written in D, split into a reusable
library and a thin command-line tool. It runs a ROM for an exact number of
instruction cycles (with an optional key schedule) and prints the 64x32 display
plus the CPU state. Behaviour follows the project's `SPEC.md`: shifts in place,
`FX55`/`FX65` leave `I` alone, sprites wrap, timers tick every 8th cycle, and
`CXNN` uses a fixed-seed LCG.

Only the D standard library (Phobos/druntime) is used.

## Layout

| Path | Purpose |
|------|---------|
| `source/chip8/machine.d` | `Machine` state and the `run` interpreter loop |
| `source/chip8/font.d` | built-in hex font |
| `source/chip8/input.d` | parser for the ROM / cycles / key-schedule text format |
| `source/chip8/output.d` | `render`: the 34-line textual report |
| `source/chip8/package.d` | `import chip8;` re-exports everything |
| `app/main.d` | the command-line tool |
| `tests/` | unit tests (separate from the library source) |

The interpreter loop is a single function with the hot registers in locals, one
`switch` on the top nibble, and the display held as 32 `ulong` row words so a
sprite row is a rotate, an AND and an XOR.

## Build

Requires LDC and dub.

```
./build.sh          # dub build -b release --compiler=ldc2 --config=cli
dub test --compiler=ldc2
```

This produces the `chip8` executable in this directory.

## Command-line usage

The tool reads the program from stdin and writes the report to stdout:

```
<rom-hex>
<cycles>
<key-schedule>      (optional: "cycle:mask" events separated by spaces)
```

```
$ printf '60ff7001610180141208\n6\n' | ./run.sh
................................................................
... (32 display rows)
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

`mask` is four hex digits; bit `k` set means key `k` is held down from just
before that cycle. Malformed input exits with status 2 and a message on stderr.

## Library example

```d
import std.stdio : write;
import chip8;

void main()
{
    // V0 = 0xFF; V0 += 1; V1 = 1; V0 += V1; jump to self
    auto program = parseProgram("60ff7001610180141208\n6\n");

    auto machine = makeMachine(program.rom);
    run(machine, program.cycles, program.events);

    assert(machine.v[0] == 1);
    write(render(machine));          // the same report the CLI prints
}
```

`Machine` is a plain struct (memory, registers, stack, `pc`, `i`, timers,
display rows), so you can also build one by hand, poke `mem`, call `run` with a
`KeyEvent[]` schedule, and inspect any field afterwards. `run` numbers cycles
from 0 on every call, so key-event cycles are relative to that call.

## Tests

`dub test --compiler=ldc2` runs the unit tests in `tests/`. The end-to-end
suite lives one directory up: `python3 run_tests.py chip8 -- chip8/run.sh`.
