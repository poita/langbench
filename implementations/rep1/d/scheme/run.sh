#!/bin/sh
# Run the interpreter: Scheme program on stdin, output on stdout.
exec "$(dirname "$0")/bin/scheme" "$@"
