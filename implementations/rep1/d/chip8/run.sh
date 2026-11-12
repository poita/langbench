#!/bin/sh
# Run the chip8 tool: input on stdin, report on stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
exec "$DIR/bin/chip8" "$@"
