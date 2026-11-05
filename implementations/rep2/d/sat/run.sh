#!/bin/sh
# Run the sat CLI: DIMACS CNF on stdin, SAT/UNSAT answer on stdout.
exec "$(dirname "$0")/bin/sat-cli" "$@"
