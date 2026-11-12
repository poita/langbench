# chip8

A deterministic CHIP-8 interpreter in Clojure: a small reusable library plus a
thin command-line tool. It loads a ROM, executes an exact number of cycles
(with an optional key schedule) and prints the 64×32 display and CPU state.
The exact semantics (shifts, `FX55`/`FX65`, `BNNN`, sprite wrapping, timer
rate, RNG) are defined by the project's `SPEC.md`.

The interpreter fetches and decodes from memory on every cycle (no
pre-decoding or caching), so self-modifying programs work; the machine state
is held in primitive arrays, giving millions of cycles per second.

## Requirements

Clojure 1.12.6 (`clojure` CLI) on Java 27. No runtime dependencies beyond
Clojure itself.

## Build

```
./build.sh
```

AOT-compiles the CLI into `target/classes` and caches the classpath in
`target/classpath`. `run.sh` uses both, so it works from any directory.

## Command line

`run.sh` reads a job from stdin and writes the report to stdout:

```
<rom-hex>            ROM bytes, lowercase hex, loaded at 0x200
<cycles>             number of cycles to execute (0..4000000000)
<key-schedule>       optional: space-separated <cycle>:<mask> events,
                     mask = 4 hex digits, bit k = key k held
```

```
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The output is 32 display rows of 64 `#`/`.` characters, a
`PC=… I=… SP=… DT=… ST=…` line and a `V=…` register line.

Without building, `echo … | clojure -M:run` does the same.

## Library

Source layout (`src/chip8/`):

| namespace       | responsibility                                          |
|-----------------|---------------------------------------------------------|
| `chip8.core`    | public API: `run-rom`, `emulate`, `snapshot`, `report`  |
| `chip8.machine` | machine state (primitive arrays), `new-machine`, `set-keys!`, `snapshot` |
| `chip8.cpu`     | `step!` (one cycle) and `run-cycles!` (N cycles with key schedule) |
| `chip8.input`   | parsing of the textual job format                       |
| `chip8.render`  | formatting of the 34-line report                        |
| `chip8.font`    | built-in font data                                      |
| `chip8.main`    | CLI entry point                                         |

Example:

```clojure
(require '[chip8.core :as chip8]
         '[chip8.machine :as machine]
         '[chip8.cpu :as cpu])

;; Run a ROM (a seq of byte values) for 6 cycles and inspect the result.
(def m (chip8/run-rom [0x60 0xff 0x70 0x01 0x61 0x01 0x80 0x14 0x12 0x08] 6))
(select-keys (chip8/snapshot m) [:pc :v])
;=> {:pc 520, :v [1 1 0 ...]}

;; Same as the CLI, from job text to report text.
(print (chip8/emulate "60ff7001610180141208\n6\n"))

;; Step manually with key input.
(let [m (machine/new-machine [0xf0 0x0a])]   ; FX0A: wait for key
  (cpu/step! m)                               ; no key: PC stays put
  (machine/set-keys! m 0x0004)                ; hold key 2
  (cpu/step! m)
  (:v (chip8/snapshot m)))                    ;=> [2 0 0 ...]
```

## Tests

```
clojure -M:test
```

Runs the `clojure.test` suite (including `test.check` properties) with the
Cognitect test-runner. Full acceptance tests are run by the repository's
`run_tests.py chip8 -- chip8/run.sh`.
