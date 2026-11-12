#!/bin/sh
# Runs the chip8 CLI: stdin -> stdout. Works from any directory.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/chip8"
