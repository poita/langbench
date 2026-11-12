#!/bin/sh
# Build the project (release profile). Works from any directory.
set -e
cd "$(dirname "$0")"
cargo build --release --quiet
