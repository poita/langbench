#!/bin/sh
# Build the project (release mode). Works from any current directory.
set -e
cd "$(dirname "$0")"
exec cargo build --release --quiet
