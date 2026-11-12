#!/bin/sh
# Build the kvstore command-line tool (release profile). Works from any directory.
set -e
cd "$(dirname "$0")"
cargo build --release
