# bigint

Signed arbitrary-precision integer arithmetic in Haskell, written from scratch
using only GHC's bundled libraries (`base`, `array`, `bytestring`) and
fixed-size machine integers — no `Integer`, no GMP.

* Numbers are a sign plus a magnitude stored as little-endian **base 10⁹ limbs**,
  so decimal parsing and printing are linear.
* `+`, `-`, comparison: O(n + m). Multiplication: schoolbook, O(n·m).
* Division: Knuth's Algorithm D (quotient and remainder together), O((n − m + 1)·m).
* Exponentiation: binary exponentiation.

The project has three parts: a library (`Data.BigInt`, `Data.BigInt.Magnitude`,
`Data.BigInt.Decimal`), a thin CLI (`app/`), and an hspec/QuickCheck test suite.

## Build

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # cabal build, then copies the executable to bin/bigint
cabal test          # run the test suite
```

## Command-line use

`./run.sh` reads queries from stdin, one per line, as `<a> <op> <b>` where `op`
is one of `+ - * / % ^ cmp`, and prints one result per line.

```console
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 100\n007 cmp 7\n1 / 0\n' | ./run.sh
42
-3
-1
1267650600228229401496703205376
0
error
```

* Operands match `-?[0-9]+`; leading zeros and `-0` are accepted.
* `/` truncates toward zero; `%` takes the sign of the dividend.
* `cmp` prints `-1`, `0` or `1`.
* Output is canonical (no leading zeros, never `-0`).
* Division/remainder by zero and negative exponents print `error`. `0 ^ 0` is `1`.

## Library use

Import `Data.BigInt` qualified (its names clash with the Prelude):

```haskell
{-# LANGUAGE OverloadedStrings #-}
import qualified Data.ByteString.Char8 as BC
import qualified Data.BigInt as B

main :: IO ()
main = do
  let Just a = B.parse "-123456789012345678901234567890"
      Just b = B.parse "987654321098765432109876543210"
  BC.putStrLn (B.render (B.mul a b))
  -- -121932631137021795226185032733622923332237463801111263526900

  case B.quotRem a (B.fromInt 7) of          -- Nothing on division by zero
    Just (q, r) -> print (q, r)
    Nothing     -> putStrLn "division by zero"

  print (B.pow (B.fromInt 2) (B.fromInt 100)) -- Just 1267650600228229401496703205376
```

Division and `pow` are total: they return `Maybe` (`Nothing` for a zero divisor
or a negative exponent). There is intentionally no `Num` instance, because
`fromInteger` would require consuming an `Integer`.

## Layout

| Module | Responsibility |
| --- | --- |
| `Data.BigInt` | Signed `BigInt`: sign handling, public API |
| `Data.BigInt.Magnitude` | Unsigned limb arrays and the core algorithms |
| `Data.BigInt.Decimal` | Linear-time decimal parsing/printing of magnitudes |
| `app/Query.hs`, `app/Main.hs` | Query-line evaluation and the CLI |
| `test/Spec.hs` | Unit and property tests (`Integer` is used only there, as an oracle) |
