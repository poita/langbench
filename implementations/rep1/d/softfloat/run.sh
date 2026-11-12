#!/bin/sh
# Run the softfloat tool: reads operations on stdin, writes results to stdout.
exec "$(dirname "$0")/bin/softfloat" "$@"
