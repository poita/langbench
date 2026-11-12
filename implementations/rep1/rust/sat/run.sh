#!/bin/sh
# Run the solver: DIMACS CNF on stdin, result on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/target/release/sat" "$@"
