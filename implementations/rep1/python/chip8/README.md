# chip8

A deterministic CHIP-8 interpreter in pure Python (standard library only),
packaged as a reusable library plus a thin command-line tool.

The machine follows a fully specified variant of CHIP-8 (in-place shifts,
`FX55`/`FX65` leaving `I` unchanged, `BNNN` always using `V0`, wrapping
sprites, timers ticking every 8 cycles, and a fixed 32-bit LCG random number
generator), so a given ROM, cycle budget and key schedule always produce the
same output. Every cycle fetches and decodes from memory, so self-modifying
programs work.

## Layout

```
pyproject.toml        project manifest (setuptools, src layout)
src/chip8/
  font.py             built-in hex font
  machine.py          Machine: memory, registers, stack, timers, display, RNG
  textio.py           parse the text input, render the text output, simulate()
  cli.py, __main__.py command-line tool
tests/                pytest suite
build.sh, run.sh      build and run scripts
```

## Build

There is nothing to compile; `./build.sh` byte-compiles the sources to check
them. To install as a package: `pip install .` (or `pip install -e .[test]`).

## Command line

`./run.sh` (or `python3 -m chip8` with `PYTHONPATH=src`) reads the input from
stdin and writes 34 lines to stdout.

Input (ASCII, `\n` line endings):

```
<rom-hex>            ROM bytes, lowercase hex (1-3584 bytes), loaded at 0x200
<cycles>             decimal number of cycles to execute (0..4000000000)
<key-schedule>       optional: space-separated <cycle>:<mask> events, mask = 4 hex digits
```

Output: 32 display rows of 64 characters (`#` lit, `.` unlit), then
`PC=… I=… SP=… DT=… ST=…` and `V=` followed by `V0`..`VF` in hex.

```
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

## Library

```python
from chip8 import Machine, KeyEvent, render

# V0 = 0; loop: V0 += 1; wait for a key; jump back
machine = Machine(bytes.fromhex("60007001f10a1202"))
machine.run(100, key_schedule=[KeyEvent(10, 0x0001)])  # press key 0 before cycle 10
print(machine.v[0], hex(machine.pc))
print(render(machine))          # the 34-line text output

# Or drive it one cycle at a time, setting keys yourself:
machine.keys = 1 << 0xA
machine.step()
print(machine.pixel(0, 0))
```

Public API (`chip8`): `Machine` (`run`, `step`, `load_rom`, `pixel`, and the
state attributes `memory`, `v`, `i`, `pc`, `stack`, `dt`, `st`, `keys`,
`rng_state`, `display`, `cycles`), `KeyEvent`, `parse_input`, `simulate`,
`render`, `render_display`, `render_state`, `Program`, plus the constants
`FONT`, `FONT_ADDRESS`, `PROGRAM_START`, `MAX_ROM_SIZE`, `DISPLAY_WIDTH` and
`DISPLAY_HEIGHT`.

## Tests

```
python3 -m pytest          # from this directory
```
