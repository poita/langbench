#!/bin/sh
# Run the chip8 CLI: ROM/cycles/key schedule on stdin, display and state on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/chip8" "$@"
