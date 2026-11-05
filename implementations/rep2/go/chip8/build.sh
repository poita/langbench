#!/bin/sh
# Build the chip8 command-line tool into ./bin/chip8.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/chip8 ./cmd/chip8
