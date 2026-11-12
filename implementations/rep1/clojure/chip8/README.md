# chip8

A deterministic CHIP-8 interpreter written in Clojure. It is a small reusable
library plus a thin command-line tool: it reads a ROM, a cycle budget and an
optional key schedule, runs exactly that many instruction cycles, and prints
the 64x32 display and the CPU state.

The exact machine semantics (shifts, `FX55`/`FX65`, `BNNN`, sprite wrapping,
timer rate, RNG) follow the problem specification; they intentionally pick one
behaviour where historical interpreters disagree.

## Requirements

- Java 27 and the `clojure` CLI (Clojure 1.12.6)
- Tests additionally use the Cognitect test-runner and `org.clojure/test.check`
  (declared in the `:test` alias of `deps.edn`)

## Build

```sh
./build.sh
```

This resolves dependencies and AOT-compiles the CLI into `target/classes`
(which makes start-up faster).

## Command-line usage

`./run.sh` reads the input from stdin and writes the report to stdout.

Input (ASCII, `\n` line endings):

```
<rom-hex>             ROM bytes, lowercase hex, loaded at 0x200 (1-3584 bytes)
<cycles>              number of cycles to execute, 0..4000000000
<key-schedule>        optional: events "<cycle>:<mask>" separated by spaces
```

A key event `c:mask` takes effect just before cycle `c` runs; bit `k` of the
4-hex-digit mask means key `k` is held. Output is 34 lines: 32 display rows of
`#`/`.`, a `PC=… I=… SP=… DT=… ST=…` line and a `V=…` register line.

```sh
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Errors (malformed input) are reported on stderr with exit status 1.

## Library usage

```clojure
(require '[chip8.core :as chip8])

;; V0 = 0xFF; V0 += 1; V1 = 1; V0 += V1; jump to self
(def rom [0x60 0xff  0x70 0x01  0x61 0x01  0x80 0x14  0x12 0x08])

(def m (chip8/run rom 6))          ; run 6 cycles, returns the (mutable) machine
(chip8/snapshot m)                 ;=> {:pc 520 :i 0 :sp 0 :dt 0 :st 0 :v [1 1 0 ...]}
(print (chip8/format-state m))     ; the 34-line text report

;; With a key schedule: press keys 8 and 9 before cycle 9
(chip8/run rom 14 [[9 0x0300]])

;; Lower level
(let [m (chip8/make-machine rom)]
  (chip8/step! m)                  ; execute one instruction
  (chip8/pixels m))                ; 32 rows x 64 booleans
```

### Modules

| Namespace        | Responsibility                                              |
|------------------|-------------------------------------------------------------|
| `chip8.core`     | Public API: `run`, `run!`, `make-machine`, `step!`, `snapshot`, `pixels`, `format-state`, `run-text` |
| `chip8.machine`  | Mutable machine state (memory, registers, stack, screen)    |
| `chip8.cpu`      | Fetch/decode/execute every cycle from memory; timer tick    |
| `chip8.display`  | Sprite drawing (XOR, wrapping) and text rendering           |
| `chip8.rng`      | The specified 32-bit LCG                                    |
| `chip8.font`     | Built-in font data                                          |
| `chip8.input`    | Parsing of the textual input format                         |
| `chip8.main`     | CLI entry point                                             |

Every cycle the opcode is fetched and decoded from memory (no caching or
pre-decoding), so self-modifying programs work; the key schedule is consumed in
order in O(1) per cycle.

## Tests

```sh
clojure -M:test
```

The suite contains unit tests per module, the worked examples from the
specification, and `test.check` property tests.
