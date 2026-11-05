#!/bin/sh
# Build the chip8 command-line tool into ./bin/chip8.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/chip8 ./cmd/chip8
