#!/bin/sh
# Run the chip8 tool: reads the input on stdin, writes the result to stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/chip8" "$@"
