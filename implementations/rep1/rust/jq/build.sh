#!/bin/sh
# Build the project in release mode, from any current directory.
set -e
cd "$(dirname "$0")"
cargo build --release --quiet
