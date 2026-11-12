# qrcode

A from-scratch QR Code Model 2 (ISO/IEC 18004) encoder in Clojure, with no
runtime dependencies beyond Clojure itself. It is a small library plus a
command-line tool that reads encoding queries on stdin and prints each symbol's
module matrix as text.

Supported: versions 1–40, error correction levels L/M/Q/H, numeric,
alphanumeric and byte modes (UTF-8, no ECI header), a single segment per
symbol, fixed or automatic (penalty-scored) mask selection.

## Requirements

Clojure 1.12.6 and a JDK (developed on Java 27), with the `clojure` CLI on the
`PATH`.

## Build

    ./build.sh

resolves dependencies and AOT-compiles the CLI into `target/classes` for fast
start-up. It can be run from any directory.

## Command-line usage

    echo "M auto HELLO WORLD" | ./run.sh

Input is one query per line (final newline optional):

    <ecl> <mask> <text>

* `<ecl>`: `L`, `M`, `Q` or `H`.
* `<mask>`: `0`..`7`, or `auto` to pick the mask with the lowest penalty
  (ties go to the lowest mask number).
* `<text>`: the rest of the line, interior spaces included; encoded as UTF-8
  bytes in the first applicable mode (numeric, alphanumeric, byte), in the
  smallest version that fits.

For each query the output is

    version <v> mask <m>
    <size rows of '#' (dark) and '.' (light), no quiet zone>
    <empty line>

A malformed query makes the tool print a message to stderr and exit with
status 1.

## Library usage

```clojure
(require '[qrcode.core :as qr])

(def sym (qr/encode "HELLO WORLD" :m))   ; mask defaults to :auto
(select-keys sym [:version :mask :mode :size])
;=> {:version 1, :mask 0, :mode :alphanumeric, :size 21}

(qr/dark? sym 0 0)        ;=> true (column 0, row 0 of the symbol)
(first (qr/rows sym))     ;=> "#######...#.#.#######"
(qr/matrix sym)           ; vector of rows of booleans

(qr/encode "héllo" :h 5)  ; force mask 5
(qr/encode-bytes (byte-array [1 2 3]) :q :auto)

(require '[qrcode.render :as render])
(print (render/->text sym))   ; the CLI's text format
```

`encode` throws `ex-info` when the text is empty, the level or mask is invalid,
or the payload does not fit in version 40.

### Modules

| namespace              | responsibility                                          |
|------------------------|---------------------------------------------------------|
| `qrcode.core`          | public API: `encode`, `encode-bytes`, `dark?`, `rows`, `matrix` |
| `qrcode.tables`        | capacity tables, block structure, alignment positions   |
| `qrcode.segment`       | mode selection, version selection, segment bit encoding |
| `qrcode.bits`          | append-only bit buffer                                  |
| `qrcode.reedsolomon`   | GF(2^8) arithmetic and Reed-Solomon ECC                 |
| `qrcode.codewords`     | padding, block splitting, ECC, interleaving             |
| `qrcode.matrix`        | function patterns, format/version info, data placement  |
| `qrcode.mask`          | the eight mask patterns                                 |
| `qrcode.penalty`       | N1–N4 penalty scoring                                   |
| `qrcode.render`        | text rendering                                          |
| `qrcode.cli`           | stdin/stdout tool                                       |

## Tests

    clojure -M:test

runs the unit, golden-file and `test.check` property tests with the Cognitect
test-runner.
