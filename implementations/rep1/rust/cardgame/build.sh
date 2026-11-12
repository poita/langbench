#!/bin/sh
# Build the cardgame project in release mode. Works from any directory.
set -e
cd "$(dirname "$0")"
cargo build --release --quiet
