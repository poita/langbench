#!/bin/sh
# Build the sitegen binary in release mode. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
cargo build --release --quiet
