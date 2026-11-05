#!/bin/sh
# Run the SAT solver: DIMACS CNF on stdin, result on stdout.
exec "$(dirname "$0")/bin/sat" "$@"
