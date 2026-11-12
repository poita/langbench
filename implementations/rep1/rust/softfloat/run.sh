#!/bin/sh
# Run the CLI: reads operations on stdin, writes results on stdout.
exec "$(dirname "$0")/target/release/softfloat" "$@"
