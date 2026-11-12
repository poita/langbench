#!/bin/sh
# Run the CHIP-8 CLI: reads the problem input on stdin, writes the result to stdout.
dir=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$dir/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m chip8 "$@"
