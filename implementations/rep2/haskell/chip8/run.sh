#!/bin/sh
# Run the chip8 tool: reads the problem input on stdin, writes the result on stdout.
set -e
cd "$(dirname "$0")"
exec "$(cabal list-bin -v0 exe:chip8)"
