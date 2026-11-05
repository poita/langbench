#!/bin/sh
# Runs the chip8 CLI: reads the problem input on stdin, writes the report to stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/chip8" "$@"
