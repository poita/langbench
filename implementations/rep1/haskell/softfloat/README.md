# softfloat

Software IEEE-754 binary32 arithmetic in Haskell: add, subtract, multiply,
divide and square root on raw 32-bit patterns, round-to-nearest-even with full
gradual underflow. Everything is computed with bounded-width (64-bit) integer
arithmetic: no host floating point, no big integers. Exceptions and flags are
not modelled; any NaN input or invalid operation yields the canonical quiet NaN
`7fc00000`.

## Layout

| Module | Responsibility |
| --- | --- |
| `Numeric.SoftFloat` | Public API (`f32Add`, `f32Sub`, `f32Mul`, `f32Div`, `f32Sqrt`, `qNaN`, `isNaN32`) |
| `Numeric.SoftFloat.Protocol` | Parsing/printing of the line-oriented text protocol |
| `Numeric.SoftFloat.Internal.Unpack` | Classification and unpacking of bit patterns |
| `Numeric.SoftFloat.Internal.Round` | The single shared round-and-pack step (normal and denormal grid) |
| `Numeric.SoftFloat.Internal.Ops` | Per-operation kernels (guard/sticky add, 48-bit multiply, one integer divide, restoring digit-by-digit square root) |
| `app/Main.hs` | The command-line tool |

## Build

    cabal build           # or ./build.sh
    cabal test            # hspec + QuickCheck, checked against hardware floats

## Command line

`./run.sh` (or `cabal run softfloat`) reads operations on stdin, one per line,
and prints one 8-digit lowercase hex result per line:

    $ printf 'add 3f800000 3f800000\ndiv 3f800000 40400000\nsqrt 40000000\n' | ./run.sh
    40000000
    3eaaaaab
    3fb504f3

Input lines are `<op> <a> <b>` for `add sub mul div`, or `sqrt <a>`, with
operands as 8 lowercase hex digits. Malformed input makes the tool exit with
status 1 and a message on stderr.

## Library example

```haskell
import Numeric.SoftFloat

main :: IO ()
main = do
  print (f32Div 0x3f800000 0x40400000 == 0x3eaaaaab)  -- 1/3 rounds up
  print (f32Sqrt 0x40000000 == 0x3fb504f3)             -- sqrt 2
  print (isNaN32 (f32Sub 0x7f800000 0x7f800000))       -- inf - inf
```

## Design

Finite operands are unpacked to `sig * 2^exp`. Each operation produces a
truncated integer result plus a sticky bit, and `roundPack` rounds once,
directly onto the normal or denormal grid, so there is no double rounding.
