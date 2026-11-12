#!/bin/sh
# Build the sqlitefile project (release profile).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
cargo build --release --quiet
