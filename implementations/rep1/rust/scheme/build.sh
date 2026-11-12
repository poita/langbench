#!/bin/sh
# Build the interpreter in release mode, from any current directory.
set -e
cd "$(dirname "$0")"
cargo build --release
