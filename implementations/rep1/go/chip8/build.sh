#!/bin/sh
# Builds the chip8 command-line tool into ./bin/chip8.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
mkdir -p bin
go build -o bin/chip8 ./cmd/chip8
