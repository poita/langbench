#!/bin/sh
# Run the chip8 CLI: reads the job on stdin, writes the result to stdout.
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/build/chip8" "$@"
