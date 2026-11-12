#!/bin/sh
# Build the depresolve project in release mode; works from any directory.
set -e
cd "$(dirname "$0")"
cargo build --release --quiet
