# chip8

A small, fully deterministic CHIP-8 interpreter in Haskell: a reusable library
plus a thin command-line tool.

Given a ROM, a cycle budget and an optional key schedule, it executes exactly
that many instruction cycles and prints the 64x32 display and the CPU state.
Behaviour is defined by `problems/chip8/SPEC.md` (shifts in place, `BNNN` uses
`V0`, sprites wrap, timers tick every 8 cycles, a specified LCG for `CXNN`).

Every cycle fetches and decodes the opcode from memory (no caching or
pre-decoding), so self-modifying programs work. The key schedule is consumed
in order, so a run is O(cycles).

## Build

Requires GHC 9.14 and cabal 3.18 (only GHC's bundled packages are used).

```
./build.sh          # cabal build, and copies the executable to bin/chip8
cabal test          # hspec / QuickCheck test suite
```

## Command-line use

`./run.sh` reads the program on stdin and writes the report on stdout. The
input is three lines: the ROM as lowercase hex, the cycle count, and an
optional key schedule of `cycle:mask` events (mask = 4 hex digits, bit `k` =
key `k` held).

```
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The output is 32 display rows (`#` lit, `.` unlit), a `PC=.. I=.. SP=..
DT=.. ST=..` line and a `V=..` line. Malformed input prints a message to
stderr and exits with status 1.

## Library

| Module           | Responsibility                                          |
|------------------|---------------------------------------------------------|
| `Chip8`          | Top-level `run` / `runRom`, re-exports the pure API     |
| `Chip8.Types`    | `Rom`, `KeyEvent`, `Snapshot`, display constants        |
| `Chip8.Font`     | Built-in hex font                                       |
| `Chip8.Machine`  | Mutable machine state (`ST`), masked accessors, LCG     |
| `Chip8.Execute`  | `step`, `tickTimers`, `runCycles`                       |
| `Chip8.Input`    | `parseInput` for the textual input format               |
| `Chip8.Render`   | `renderSnapshot` and its line-level pieces              |

Example: run a ROM that draws the font glyph `0` and inspect the result.

```haskell
import Chip8
import Data.Array.Unboxed ((!))

main :: IO ()
main = do
  -- V0 = 0; I = font('0'); V1 = 4; V2 = 4; draw 5 rows at (4, 4)
  let rom  = [0x60,0x00, 0xF0,0x29, 0x61,0x04, 0x62,0x04, 0xD1,0x25]
      snap = runRom rom 5 []          -- 5 cycles, no key events
  print (pixelAt snap 4 4)            -- True
  print (snapV snap ! 15)             -- 0 (no collision)
  putStr (renderSnapshot snap)        -- the full 34-line report
```

For step-by-step control, create a machine with `Chip8.Machine.newMachine`
and drive it with `Chip8.Execute.step` / `runCycles` inside `ST`, then take a
`Snapshot` with `freezeMachine`.
