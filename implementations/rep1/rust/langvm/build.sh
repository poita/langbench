#!/bin/sh
# Build the langvm project (release mode). Works from any directory.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
cargo build --release --quiet
