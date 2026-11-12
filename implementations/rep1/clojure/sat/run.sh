#!/bin/sh
# Run the SAT solver: DIMACS CNF on stdin, result on stdout.
cd "$(dirname "$0")" || exit 1
exec clojure -M -m sat.cli "$@"
