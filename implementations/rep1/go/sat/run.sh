#!/bin/sh
# Run the solver: DIMACS CNF on stdin, result on stdout. Works from any directory.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/sat" "$@"
