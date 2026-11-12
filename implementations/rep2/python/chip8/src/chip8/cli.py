"""Command-line interface: read a program on stdin, print the final state."""

import argparse
import sys
from collections.abc import Sequence

from .program import run_program


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="chip8",
        description=(
            "Run a CHIP-8 ROM for an exact number of cycles. Reads "
            "'<rom-hex>\\n<cycles>\\n[<key-schedule>]' on stdin and prints the "
            "64x32 display followed by the CPU state."
        ),
    )
    parser.parse_args(argv)
    sys.stdout.write(run_program(sys.stdin.read()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
