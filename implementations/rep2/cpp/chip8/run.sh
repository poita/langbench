#!/bin/sh
# Run the CLI: reads the problem input on stdin, writes the result to stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/chip8" "$@"
