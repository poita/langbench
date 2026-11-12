#!/bin/sh
# Run the solver: DIMACS CNF on stdin, result on stdout.
exec "$(dirname "$0")/target/release/sat" "$@"
