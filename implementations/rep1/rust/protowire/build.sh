#!/bin/sh
# Build the protowire library and command-line tool in release mode.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
exec cargo build --release --quiet
