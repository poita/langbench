#!/bin/sh
# Run the solver: DIMACS CNF on stdin, answer on stdout.
exec "$(dirname "$0")/bin/sat" "$@"
