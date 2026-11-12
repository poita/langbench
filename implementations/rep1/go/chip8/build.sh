#!/bin/sh
# Builds the chip8 CLI into bin/chip8. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
go build -o bin/chip8 ./cmd/chip8
