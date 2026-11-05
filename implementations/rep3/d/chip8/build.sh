#!/bin/sh
# Build the chip8 command-line tool into bin/chip8.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
exec dub build -b release --compiler=ldc2 --config=cli --quiet
