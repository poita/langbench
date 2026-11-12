#!/bin/sh
# Run the regex CLI: reads the batch input on stdin, writes results to stdout.
exec "$(dirname "$0")/regex" "$@"
