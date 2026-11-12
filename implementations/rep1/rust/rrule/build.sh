#!/bin/sh
# Build the rrule project (release profile). Works from any directory.
set -e
cd "$(dirname "$0")"
cargo build --release --quiet
