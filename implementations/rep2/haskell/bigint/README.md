# bigint

Arbitrary-precision signed integer arithmetic in Haskell, written from
scratch (no `Integer`, no GMP-backed types in the implementation), with a
small command-line tool that evaluates one query per line.

* Numbers are a sign plus a magnitude in **base 10^9** (little-endian
  `UArray Int Word` limbs), so parsing and printing decimal are linear.
* Addition, subtraction, comparison: linear.
* Multiplication: schoolbook, `O(n·m)`.
* Division / remainder: Knuth's Algorithm D (one quotient limb per step from a
  two-limb estimate), `O((n−m+1)·m)`; quotient and remainder come out together.
* Exponentiation: left-to-right binary exponentiation.
* Division truncates toward zero; the remainder has the sign of the dividend.
  There is no negative zero.

Only `base`, `array` and `bytestring` (all bundled with GHC) are used by the
library; the tests additionally use `hspec` and `QuickCheck`.

## Layout

| Module | Responsibility |
| --- | --- |
| `Numeric.BigInt` | Public API: signed `BigInt`, parse/render, `addBig`, `subBig`, `mulBig`, `quotRemBig`, `powBig`, `Eq`/`Ord`/`Show`/`Read`/`Num` instances |
| `Numeric.BigInt.Magnitude` | Unsigned limb arithmetic (`Mag`): the algorithms above |
| `Numeric.BigInt.Query` | Parses and evaluates `a op b` query lines (used by the CLI) |
| `app/Main.hs` | Thin CLI: stdin → `evalInput` → stdout |

## Build

```
./build.sh          # cabal build exe:bigint, copies the binary to bin/bigint
cabal test          # run the test suite (hspec + QuickCheck, Integer as oracle)
```

Requires GHC 9.14 and cabal 3.18.

## Command-line use

`./run.sh` reads queries from standard input, one per line, `<a> <op> <b>`
with `op` one of `+ - * / % ^ cmp`, and prints one line per query:

```
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n007 cmp 7\n2 ^ 100\n1 / 0\n' | ./run.sh
42
-3
-1
0
1267650600228229401496703205376
error
```

Operands match `-?[0-9]+` (leading zeros and `-0` are fine); results are
canonical (no leading zeros, never `-0`). `cmp` prints `-1`, `0` or `1`.
`error` is printed for division/remainder by zero and for a negative
exponent. `0 ^ 0 = 1`.

## Library example

```haskell
import qualified Data.ByteString.Char8 as BC
import Data.Maybe (fromJust)
import Numeric.BigInt

main :: IO ()
main = do
  let n   = fromJust (parseBigInt (BC.pack "123456789012345678901234567890"))
      sq  = n `mulBig` n
      Just (q, r) = sq `quotRemBig` fromInt 97
      Just p = powBig (fromInt (-2)) (fromInt 101)
  BC.putStrLn (renderBigInt sq)  -- 15241578753238836750495351562536198787501905199875019052100
  print (q, r)
  print p                        -- -2535301200456458802993406410752
  print (n * 2 + 1 :: BigInt)    -- the Num instance works too
```

`quotRemBig` returns `Nothing` for a zero divisor and `powBig` returns
`Nothing` for a negative exponent. For bases other than 0, 1 and −1 the
exponent must fit in a machine word.

`fromInteger` (used for numeric literals) reads its argument 32 bits at a
time; all arithmetic is done by this library.
