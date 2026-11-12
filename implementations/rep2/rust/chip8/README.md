# chip8

A small, deterministic CHIP-8 interpreter written in Rust using only the
standard library. It is split into a reusable library and a thin command-line
tool.

"Deterministic" means every historically ambiguous behaviour (shifts,
`FX55`/`FX65`, `BNNN`, sprite wrapping, timer rate, randomness) is fixed: the
timers tick once every 8 cycles, the RNG is a specified LCG, sprites wrap around
the screen edges, and all memory accesses wrap at 12 bits.

## Build

```sh
cargo build --release      # or ./build.sh
cargo test                 # unit, integration and doc tests
```

The binary is `target/release/chip8`; `./run.sh` runs it from any directory.

## Command-line usage

The tool reads a job from stdin and prints the final machine state to stdout:

```
<rom-hex>             ROM bytes, lowercase hex, loaded at 0x200 (1..=3584 bytes)
<cycles>              number of instruction cycles to execute (0..=4000000000)
<key-schedule>        optional: events "<cycle>:<mask4hex>" separated by spaces
```

A schedule event `c:mask` sets the held-key bitmask (bit `k` = key `k`)
immediately before cycle `c` executes. Output is 34 lines: the 32 display rows
(`#` lit, `.` unlit), then `PC=… I=… SP=… DT=… ST=…`, then `V=` and the sixteen
registers.

```sh
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Malformed input prints a message to stderr and exits with status 1.

## Library usage

```rust
use chip8::{render, Job, KeyEvent, KeySchedule, Machine};

fn main() {
    // Parse the textual format...
    let job = Job::parse("60ff7001610180141208\n6\n").unwrap();
    let mut machine = Machine::new();
    machine.load_rom(&job.rom).unwrap();
    machine.run(job.cycles, &job.schedule);
    print!("{}", render::render(&machine));

    // ...or drive a machine directly.
    let mut m = Machine::new();
    m.load_rom(&[0xF0, 0x0A, 0x12, 0x02]).unwrap(); // wait for a key
    let schedule = KeySchedule::from_events(vec![KeyEvent { cycle: 2, mask: 1 << 5 }]).unwrap();
    m.run(3, &schedule);
    assert_eq!(m.registers()[0], 5);
}
```

## Layout

| Module    | Responsibility                                   |
|-----------|--------------------------------------------------|
| `machine` | memory, registers, timers, instruction execution |
| `display` | 64×32 frame buffer with XOR/wrap drawing         |
| `keys`    | key events and schedules                         |
| `rng`     | the specified 32-bit LCG                         |
| `font`    | built-in hex font                                |
| `input`   | parsing the job format                           |
| `render`  | formatting the output                            |
| `error`   | error types                                      |

Every cycle fetches and decodes the opcode from memory (no caching or
pre-decoding), and the key schedule is consumed in order, so a run is
O(cycles + input size).

## Notes

Stack overflow/underflow is unspecified by the spec; the interpreter ignores
the offending push/pop rather than panicking.
