#!/bin/sh
# Build the linalg project (release mode). Works from any directory.
set -e
cd "$(dirname "$0")"
cargo build --release --quiet
