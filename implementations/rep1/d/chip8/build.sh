#!/bin/sh
# Build the chip8 command-line tool (bin/chip8) with dub + LDC.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
exec dub build -b release --compiler=ldc2 :cli
