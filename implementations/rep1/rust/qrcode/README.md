# qrcode

A dependency-free QR Code Model 2 encoder (ISO/IEC 18004) written in Rust. It
turns a byte string into a QR symbol (versions 1-40, error correction levels
L/M/Q/H, all eight masks or automatic mask selection by penalty scoring) and
exposes the module matrix. A small command-line tool prints symbols as text.

Only the standard library is used. Numeric, alphanumeric and byte modes are
supported (a single segment, mode chosen automatically); no ECI header is
emitted.

## Build

```sh
cargo build --release     # or ./build.sh
cargo test                # unit and integration tests
```

The binary is `target/release/qrcode`; `./run.sh` runs it from any directory.

## Command-line usage

The tool reads queries from standard input, one per line:

```
<ecl> <mask> <text>
```

* `<ecl>`: `L`, `M`, `Q` or `H`
* `<mask>`: `0`..`7`, or `auto` to pick the lowest-penalty mask (ties go to the lowest number)
* `<text>`: the rest of the line (UTF-8, taken as bytes)

For each query it prints `version <v> mask <m>`, then the rows of the symbol
(`#` dark, `.` light, no quiet zone), then an empty line.

```console
$ echo "L auto 01234567" | ./run.sh
version 1 mask 3
#######.##..#.#######
...
```

A malformed line or a payload that fits no version makes the tool print a
message to stderr and exit with a nonzero status.

## Library usage

```rust
use qrcode::{Ecl, MaskChoice, QrCode};

fn main() -> Result<(), qrcode::Error> {
    let qr = QrCode::encode_text("HELLO WORLD", Ecl::Medium, MaskChoice::Auto)?;
    println!("version {} mask {}", qr.version().number(), qr.mask());
    for y in 0..qr.size() {
        let row: String = (0..qr.size())
            .map(|x| if qr.get(x, y) { '#' } else { '.' })
            .collect();
        println!("{row}");
    }
    Ok(())
}
```

## Layout

| module          | responsibility                                          |
|-----------------|---------------------------------------------------------|
| `segment`       | modes, character-count widths, segment bit stream       |
| `version`       | versions, codeword and block counts                     |
| `codewords`     | terminator/padding, block split, ECC, interleaving      |
| `reed_solomon`  | GF(2^8) arithmetic, generator polynomial, remainder     |
| `matrix`        | function patterns, zigzag placement, masks, format info |
| `penalty`       | N1-N4 penalty scoring for automatic mask selection      |
| `query`         | parsing of the CLI's input lines                        |

Function patterns and data are laid out once per symbol; each mask is then
applied to a copy and scored in full.
