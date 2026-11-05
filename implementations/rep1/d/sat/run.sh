#!/bin/sh
# Run the sat solver: DIMACS CNF on stdin, result on stdout.
exec "$(dirname "$0")/sat" "$@"
