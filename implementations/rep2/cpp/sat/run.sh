#!/bin/sh
# Runs the solver: DIMACS CNF on stdin, answer on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/sat"
