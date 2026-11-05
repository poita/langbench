# chip8

A deterministic CHIP-8 interpreter written in D, split into a reusable library
and a thin command-line tool. It reads a ROM, a cycle budget and an optional key
schedule, runs exactly that many instruction cycles, and prints the 64x32
display and the CPU state. The semantics (shifts, `FX55`/`FX65`, `BNNN`, sprite
wrapping, timers, RNG) are fully specified so output is reproducible.

Only the D standard library (Phobos/druntime) is used.

## Layout

| Path | Purpose |
|------|---------|
| `source/chip8/machine.d` | `Machine` state struct, constants, font |
| `source/chip8/cpu.d` | `run` (the fetch/decode/execute loop), `KeyEvent`, `drawSprite`, RNG |
| `source/chip8/input.d` | `parseProgram`: text format → ROM, cycles, key events |
| `source/chip8/output.d` | `formatState`: display and registers → 34-line report |
| `source/chip8/package.d` | `import chip8;` re-exports all of the above |
| `app/main.d` | the command-line tool |
| `tests/` | unit tests (separate from the library sources) |

## Build

Requires LDC (1.41) and dub (1.40).

```
./build.sh          # dub build -b release --compiler=ldc2, produces bin/chip8
dub test --compiler=ldc2
```

## CLI

`bin/chip8` (or `./run.sh`) reads from stdin:

```
<rom-hex>             ROM bytes, lowercase hex, loaded at 0x200 (1-3584 bytes)
<cycles>              number of cycles to execute (0..4000000000)
<key-schedule>        optional: "<cycle>:<mask4hex>" events separated by spaces
```

and writes 34 lines: 32 display rows of `#`/`.`, then
`PC=.... I=.... SP=n DT=.. ST=..`, then `V=` and the 16 registers.
Malformed input gives a message on stderr and exit status 1.

```
$ echo '60ff7001610180141208
6' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

## Library

Use the `library` configuration as a dependency
(`dependency "chip8" path="../chip8"` / `subConfiguration "chip8" "library"`).

```d
import chip8;
import std.stdio : write;

void main()
{
    auto prog = parseProgram("6a3e6b1e6000f029dab5dab5\n5\n");

    auto m = Machine.create();       // font installed, PC = 0x200
    m.loadRom(prog.rom);
    run(m, prog.cycles, prog.events); // execute exactly 5 cycles

    assert(m.v[0xA] == 0x3e);
    assert(m.pixel(62, 30));          // sprite drawn at (62, 30), wrapping around
    write(formatState(m));            // the 34-line report
}
```

`run` can be called repeatedly; the machine tracks the number of cycles
executed (`Machine.cycle`), and key events use absolute cycle numbers.
Instructions are decoded from memory on every cycle, so self-modifying code
works.

## Design notes

* The cycle loop is a single function with the hot scalars in locals and one
  `switch` on the opcode's top nibble; no pre-decoding or handler tables.
* The display is 32 `ulong` rows (column 0 = most significant bit); sprite rows
  are placed with a 64-bit rotate, so wrap-around is free and a draw costs one
  AND and one XOR per row.
* Behaviour for pushing a 17th stack entry or popping an empty stack is
  unspecified; this implementation indexes the stack modulo 16 rather than
  trapping.
