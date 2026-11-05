#!/bin/sh
# Build the chip8 command-line tool (bin/chip8). Works from any directory.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --quiet
