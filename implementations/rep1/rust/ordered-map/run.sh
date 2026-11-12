#!/bin/sh
# Run the CLI: reads commands on stdin, writes results to stdout.
exec "$(dirname "$0")/target/release/ordered-map" "$@"
