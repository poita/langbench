#!/bin/sh
# Run the chip8 CLI: reads the problem input on stdin, writes the result to stdout.
exec "$(dirname "$0")/chip8" "$@"
