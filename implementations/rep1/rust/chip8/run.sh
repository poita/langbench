#!/bin/sh
# Run the chip8 CLI: reads the input on stdin, writes the result to stdout.
exec "$(dirname "$0")/target/release/chip8" "$@"
