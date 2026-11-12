# qrcode

A small, dependency-free QR Code Model 2 (ISO/IEC 18004) encoder in pure
Python (standard library only), plus a command-line tool that prints symbols as
text matrices.

It encodes one segment per symbol, choosing numeric, alphanumeric or byte mode
automatically (no ECI header), picks the smallest version 1..40 that fits at the
requested error-correction level (L/M/Q/H), and either uses a fixed mask
pattern (0..7) or selects the lowest-penalty one.

## Layout

```
src/qrcode/
  tables.py       capacity tables, ECC levels, alignment positions
  segments.py     mode selection, bit-stream construction, padding
  reedsolomon.py  GF(2^8) arithmetic and Reed-Solomon ECC
  layout.py       function patterns, format/version info, zigzag data order
  masking.py      mask patterns and their application
  penalty.py      mask penalty rules N1-N4
  encoder.py      encode_bytes / encode_text, block interleaving
  symbol.py       QrCode result type
  cli.py          command-line interface
tests/            pytest suite
```

## Build

```sh
./build.sh      # byte-compiles the package; no install step is needed
```

Requires Python 3.10+ (developed on 3.14). `pyproject.toml` is a standard
setuptools layout, so `pip install .` also works; `pip install .[test]` adds
pytest.

## Command-line use

`run.sh` reads queries on stdin, one per line, in the form
`<ecl> <mask> <text>`, where `<ecl>` is `L`, `M`, `Q` or `H`, `<mask>` is `0`..`7`
or `auto`, and `<text>` is the rest of the line (UTF-8, interior spaces allowed).

```sh
printf 'M 0 HELLO WORLD\nL auto 01234567\n' | ./run.sh
```

For each query it prints `version <v> mask <m>`, then the rows of the symbol
(`#` dark, `.` light, no quiet zone), then an empty line. A malformed query or
a payload too large for version 40 stops processing with a message on stderr
and exit status 1 (output for earlier queries is still written).

## Library use

```python
from qrcode import encode_text, ErrorCorrection

qr = encode_text("HELLO WORLD", ErrorCorrection.M)    # mask=None -> automatic
print(qr.version, qr.mask, qr.size)                    # 1 0 21
print(qr.to_text())                                    # '#' / '.' rows
dark = qr.get_module(0, 0)                             # True
matrix = qr.to_matrix()                                # list[list[bool]]

forced = encode_text("héllo", "H", mask=5)             # fixed mask, UTF-8 bytes
raw = encode_bytes(b"\x00\x01", "L")                   # from qrcode import encode_bytes
```

`DataTooLongError` (a `ValueError`) is raised when the payload fits no version.

## Tests

```sh
python3 -m pytest
```
