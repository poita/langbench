# softfloat

Software IEEE-754 binary32 (single-precision) addition, subtraction,
multiplication, division and square root, implemented with integer operations
only (no host floating point, no `math.sqrt`/`math.isqrt`). Rounding is
round-to-nearest-even with full gradual underflow; every NaN result is the
canonical quiet NaN `7fc00000`. Operands and results are raw 32-bit patterns.

## Layout

- `src/softfloat/bits.py` – field masks, classification, unpack/normalise.
- `src/softfloat/rounding.py` – `round_pack`, the single rounding step.
- `src/softfloat/ops.py` – `add`, `sub`, `mul`, `div`, `sqrt` (guard/sticky
  alignment, one integer divide, restoring digit-by-digit square root).
- `src/softfloat/api.py` – hex parsing/formatting and line evaluation.
- `src/softfloat/cli.py` – the command-line tool.
- `tests/` – pytest suite (with an independent reference oracle).

## Build

Pure Python 3.14, standard library only. `./build.sh` byte-compiles the
sources; there is no install step. (`pip install .` also works via
`pyproject.toml`, and installs a `softfloat` command.)

## CLI

`./run.sh` reads one operation per line on stdin and writes one 8-digit
lowercase hex result per line on stdout:

    $ printf 'add 3f800000 3f800000\nsqrt 40000000\n' | ./run.sh
    40000000
    3fb504f3

Lines are `<op> <a> <b>` for `add sub mul div` and `sqrt <a>`; operands are
8 hex digits. A malformed line gives a message on stderr and exit status 1.

## Library

```python
from softfloat import add, div, sqrt, format_bits

format_bits(div(0x3F800000, 0x40400000))   # '3eaaaaab'  (1/3)
format_bits(sqrt(0x40000000))              # '3fb504f3'  (sqrt 2)
format_bits(add(0x7F7FFFFF, 0x73000000))   # '7f800000'  (overflow to +inf)
```

## Tests

    PYTHONPATH=src python3 -m pytest

The tests compare against a reference oracle on tens of thousands of random and
edge-case operands, plus the worked examples from the spec.
