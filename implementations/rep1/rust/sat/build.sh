#!/bin/sh
# Build the project in release mode, from any current directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
exec cargo build --release --quiet
