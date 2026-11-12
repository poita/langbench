#!/bin/sh
# Build the project (release profile). Works from any current directory.
set -e
cd "$(dirname "$0")"
cargo build --release
