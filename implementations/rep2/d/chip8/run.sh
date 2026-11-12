#!/bin/sh
# Run the chip8 tool: ROM/cycles/key schedule on stdin, display + CPU state on stdout.
exec "$(dirname "$0")/bin/chip8" "$@"
