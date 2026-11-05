#!/bin/sh
# Run the softfloat command: reads operations on stdin, writes results to stdout.
exec "$(dirname "$0")/bin/softfloat" "$@"
