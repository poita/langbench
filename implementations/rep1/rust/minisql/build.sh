#!/bin/sh
# Build the minisql command-line tool (release mode).
set -e
cd "$(dirname "$0")"
cargo build --release
