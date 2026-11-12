#!/bin/sh
# Run the chip8 CLI: program on stdin, report on stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
exec "$dir/bin/chip8" "$@"
