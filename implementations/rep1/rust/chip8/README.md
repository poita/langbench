# chip8

A deterministic CHIP-8 interpreter, as a reusable Rust library plus a thin
command-line tool. It runs a ROM for an exact number of instruction cycles
(with an optional key schedule) and prints the 64×32 display and the CPU
state. Behaviour on every historically ambiguous point (shifts, `FX55`/`FX65`,
`BNNN`, sprite wrapping, timers, randomness) is fixed by the specification the
project implements, so runs are fully reproducible. Only the standard library
is used.

## Build

```sh
./build.sh            # or: cargo build --release
```

The binary is `target/release/chip8`; `./run.sh` runs it from any directory.

## Command-line use

The program reads three lines on stdin and writes 34 lines to stdout:

```
<rom-hex>             ROM bytes, lowercase hex (1..3584 bytes), loaded at 0x200
<cycles>              number of cycles to execute, 0..=4000000000
<key-schedule>        optional: events "<cycle>:<mask4hex>" separated by spaces
```

An event `c:mask` makes keys `k` with bit `1 << k` set in `mask` held down
from just before cycle `c` until the next event. Output is the display (32
lines of 64 `#`/`.` characters), then
`PC=… I=… SP=… DT=… ST=…`, then `V=` and the 16 registers.

```sh
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Malformed input prints a message to stderr and exits with status 1.

## Library

Modules: `machine` (CPU and memory), `display`, `keys` (key schedule),
`rng` (the specified LCG), `font`, `input` (parsing), `output` (report
formatting) and `error`. Every cycle is interpreted from memory, so
self-modifying programs work.

```rust
use chip8::{Input, Machine};

let input = Input::parse("6a3e6b1e6000f029dab5\n5\n").unwrap();
let mut machine = Machine::new(&input.rom).unwrap();
machine.run(input.cycles, &input.keys);

assert_eq!(machine.v[0xA], 0x3e);
assert!(machine.display.get(62, 30));
println!("{}", chip8::output::Report(&machine));
```

`chip8::run_text` does the whole parse–run–render pipeline in one call.
API docs: `cargo doc --open`.

## Tests

```sh
cargo test
```

Unit tests live beside the modules, integration tests (the worked examples
from the specification and per-instruction checks) in `tests/`, and the
doc-tests cover the examples in the API documentation.
