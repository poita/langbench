#!/bin/sh
# Run the chip8 CLI: reads the problem input on stdin, writes the result on stdout.
exec "$(dirname "$0")/target/release/chip8" "$@"
