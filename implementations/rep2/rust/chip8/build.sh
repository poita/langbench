#!/bin/sh
# Build the chip8 project (release mode). Works from any directory.
set -e
cd "$(dirname "$0")"
cargo build --release --quiet
