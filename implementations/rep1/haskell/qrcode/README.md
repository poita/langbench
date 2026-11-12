# qrcode

A from-scratch **QR Code Model 2** (ISO/IEC 18004) encoder in Haskell: a small
reusable library plus a command-line tool that prints symbols as text. It
depends only on GHC's bundled packages (`base`, `array`, `bytestring`, `text`);
the tests additionally use `hspec` and `QuickCheck`.

It encodes a payload as a single segment (numeric, alphanumeric or byte mode —
the first that applies), picks the smallest version 1..40 that fits at the
requested error correction level, adds Reed-Solomon error correction, and
applies a fixed mask or the lowest-penalty one. No ECI header is emitted;
text is encoded as its UTF-8 bytes.

## Build

Requires GHC 9.14 and cabal 3.18.

    ./build.sh            # cabal build exe:qrcode
    cabal test            # run the test suite

## Command-line use

`./run.sh` reads queries on stdin, one per line, and writes one block per query
to stdout:

    <ecl> <mask> <text>

* `ecl`: `L`, `M`, `Q` or `H`
* `mask`: `0`..`7`, or `auto` to choose by penalty score (lowest number wins ties)
* `text`: the rest of the line (may contain spaces and UTF-8)

Each block is `version <v> mask <m>`, then `4v+17` rows of `#` (dark) and `.`
(light), then an empty line:

    $ echo 'L auto 01234567' | ./run.sh
    version 1 mask 3
    #######.##..#.#######
    ...

A malformed query or one that does not fit in version 40 makes the tool print a
message on stderr and exit with status 1 (output for earlier queries is kept).

## Library use

```haskell
import qualified Data.ByteString.Char8 as BC
import Codec.QRCode

main :: IO ()
main =
  case encode M AutoMask (BC.pack "HELLO WORLD") of
    Left err -> putStrLn ("cannot encode: " ++ show err)
    Right qr -> do
      putStrLn ("version " ++ show (qrVersion qr) ++ ", mask " ++ show (qrMask qr))
      mapM_ (putStrLn . map (\b -> if b then '#' else '.')) (qrRows qr)
```

`encode :: Ecl -> MaskChoice -> ByteString -> Either QRError QRCode` is the
entry point (`encodeText` takes `Text`). `moduleAt qr x y` queries a module,
`renderSymbol` produces the CLI block as a `Builder`, and `penaltyScore`
exposes the mask penalty.

## Layout

| Module | Responsibility |
| --- | --- |
| `Codec.QRCode` | Public API: `encode`, `encodeText` |
| `Codec.QRCode.Types` | `Ecl`, `Mode`, `MaskChoice`, `QRCode`, `QRError` |
| `Codec.QRCode.Tables` | Block/ECC tables, capacities, alignment positions |
| `Codec.QRCode.Segment` | Mode selection, bit lengths, version choice, segment bits |
| `Codec.QRCode.ReedSolomon` | GF(2^8) arithmetic, generator polynomial, ECC remainder |
| `Codec.QRCode.Codewords` | Bit packing, padding, block splitting, interleaving |
| `Codec.QRCode.Matrix` | Function patterns, zigzag placement, masks, format/version info |
| `Codec.QRCode.Penalty` | Mask penalty rules N1–N4 |
| `Codec.QRCode.Render` | Text rendering |
| `Codec.QRCode.Query` | Parsing and processing of the CLI query lines |

Per query the version is chosen from closed-form bit lengths, the function
patterns and data are placed once (O(n²)), and `auto` scores all eight masks in
full on the finished symbol.
