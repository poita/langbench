# chip8

A deterministic CHIP-8 interpreter in pure Python (standard library only),
packaged as a reusable library plus a thin command-line tool. The exact
semantics (shifts, `FX55`/`FX65`, `BNNN`, sprite wrapping, timer rate, RNG)
are those of the problem's `SPEC.md`, not of any historical interpreter.

## Layout

```
src/chip8/
  constants.py  machine parameters and the built-in font
  rng.py        Lcg: the 32-bit linear congruential generator behind CXNN
  display.py    Display: 64x32 frame buffer, XOR sprite drawing with wrap-around
  machine.py    Machine: state and the fetch-decode-execute loop
  schedule.py   KeyEvent, key-schedule parsing and run_with_schedule()
  program.py    parse_program(), format_state(), run_program(): the text format
  cli.py        command-line entry point (python -m chip8)
tests/          pytest suite
```

Opcodes are fetched from memory and decoded on every cycle (no caching or
pre-decoding), so self-modifying programs behave correctly.

## Build

There is nothing to install. `./build.sh` byte-compiles the sources (a syntax
check); the project is run directly from `src/` with `PYTHONPATH` set.
Requires Python 3.14 (`pyproject.toml` is also provided for `pip install .`).

## Command line

```
./run.sh < input.txt
```

Input (stdin):

```
<rom-hex>             ROM bytes, lowercase hex, loaded at 0x200
<cycles>              number of instruction cycles to execute
<key-schedule>        optional: "<cycle>:<mask4hex> ..." events
```

Output: 32 lines of 64 characters (`#` lit, `.` unlit), then
`PC=… I=… SP=… DT=… ST=…` and `V=` followed by the 16 registers.

```
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

## Library

```python
from chip8 import Machine, KeyEvent, run_with_schedule, format_state

# V0 = 3; wait for a key; V1 = 7
machine = Machine(bytes.fromhex("6003f10a6107"))
run_with_schedule(machine, 20, [KeyEvent(5, 0b100)])   # key 2 held from cycle 5
print(machine.v[1], hex(machine.pc))
print(format_state(machine))
```

Main entry points:

- `Machine(rom)` with `.run(cycles)`, `.step()`, `.set_keys(mask)` and public
  state (`memory`, `v`, `i`, `pc`, `sp`, `stack`, `dt`, `st`, `display`, ...).
- `run_with_schedule(machine, cycles, events)` runs to a total cycle count,
  applying key events in order in O(1) per event.
- `parse_program(text)`, `format_state(machine)`, `run_program(text)` for the
  textual I/O format.

Behaviour for a 17th stack push or a pop on an empty stack is unspecified;
the stack index wraps modulo 16 rather than raising.

## Tests

```
python3 -m pytest chip8        # from the parent directory, or: cd chip8 && python3 -m pytest
```
