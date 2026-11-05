#!/bin/sh
# Build the chip8 CLI with dub + LDC (release mode).
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --config=cli --quiet
