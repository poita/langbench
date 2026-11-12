# chip8

A small, fully deterministic CHIP-8 interpreter in Haskell: a reusable library
plus a thin command-line tool.

The program reads a ROM, a cycle budget and an optional key schedule, executes
exactly that many instruction cycles, and prints the 64×32 display and the CPU
state. Every ambiguity of historical CHIP-8 (shifts, `FX55`/`FX65`, `BNNN`,
sprite wrapping, timer rate, randomness) is fixed by the specification in
`problems/chip8/SPEC.md`.

Every cycle fetches and decodes the opcode from memory (no pre-decoding or
caching), so self-modifying programs work. Only GHC's bundled libraries
(`base`, `array`, `bytestring`) are used; the tests additionally use `hspec`
and `QuickCheck`.

## Building

```sh
./build.sh            # or: cabal build exe:chip8
```

Tested with GHC 9.14.1 and cabal 3.18.2.0.

## Command-line use

`run.sh` (or the `chip8` executable) reads stdin and writes stdout:

```
<rom-hex>             ROM bytes as lowercase hex (1..3584 bytes), loaded at 0x200
<cycles>              number of instruction cycles to run (0..4000000000)
<key-schedule>        optional: space-separated <cycle>:<mask> events
```

A mask is four hex digits, bit `k` set meaning key `k` is held from just before
that cycle onwards. The output is 32 display lines of `#`/`.`, then
`PC=… I=… SP=… DT=… ST=…`, then `V=` and the 16 registers.

```sh
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Malformed input makes the tool print a message to stderr and exit with status 1.

## Library use

```haskell
import Chip8
import qualified Data.ByteString as B

main :: IO ()
main = do
  -- V0 = 0x2a; I = font glyph for V0; draw it at (V1, V2) = (0, 0)
  let rom = B.pack [0x60, 0x2a, 0xf0, 0x29, 0xd1, 0x25]
      snap = runRom rom 3 []        -- ROM, cycle count, key events
  print (snapPC snap)               -- 518 (0x206)
  print (pixelAt snap 0 0)          -- True
  putStr (render snap)              -- the full 34-line report
```

Key events are `KeyEvent cycle mask` values; `parseInput` parses the textual
format into an `Input`, and `runInput` runs it.

### Modules

| Module              | Responsibility                                          |
|---------------------|---------------------------------------------------------|
| `Chip8`             | Public facade re-exporting the usual API                |
| `Chip8.Input`       | Parsing the textual input (`parseInput`, `KeyEvent`)    |
| `Chip8.Instruction` | Pure opcode decoder (`decode`, `Instruction`)           |
| `Chip8.Machine`     | Mutable machine in `ST`; `step` runs one cycle          |
| `Chip8.Run`         | `runRom` / `runInput`: run N cycles under a key schedule |
| `Chip8.Snapshot`    | Immutable view of CPU state and display                 |
| `Chip8.Output`      | Text rendering of a snapshot                            |
| `Chip8.Font`        | The built-in hex font                                   |

For single-stepping, use `Chip8.Machine` directly:
`newMachine`, `setKeys`, `step`, `snapshot`.

## Tests

```sh
cabal test --enable-tests
```

The suite (hspec + QuickCheck) covers input parsing, decoding, instruction
semantics, rendering, and the worked examples from the specification. The
end-to-end problem tests are run with
`python3 run_tests.py chip8 -- chip8/run.sh` from the repository root.

## Notes

Behaviour on a 17th push or a pop from an empty stack is unspecified by the
spec; here the stack pointer saturates at 16 / 0 and nothing crashes.
