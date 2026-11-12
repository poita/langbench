#!/bin/sh
# Run the interpreter: Scheme program on stdin, results on stdout.
exec "$(dirname "$0")/bin/scheme" "$@"
