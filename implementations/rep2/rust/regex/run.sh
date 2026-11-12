#!/bin/sh
# Run the CLI: reads the batch input on stdin, writes results to stdout.
exec "$(dirname "$0")/target/release/btregex" "$@"
