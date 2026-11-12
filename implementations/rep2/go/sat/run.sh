#!/bin/sh
# Run the sat command: DIMACS CNF on stdin, result on stdout.
exec "$(dirname "$0")/bin/sat" "$@"
