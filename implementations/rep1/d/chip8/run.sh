#!/bin/sh
# Run the chip8 tool: reads the ROM/cycles/key schedule on stdin, writes the result to stdout.
exec "$(dirname "$0")/bin/chip8" "$@"
