#!/bin/sh
# Run the regex tool: batch input on stdin, results on stdout.
exec "$(dirname "$0")/regex" "$@"
