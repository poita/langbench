#!/bin/sh
# Build the project in release mode. Works from any current directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
cargo build --release --quiet
