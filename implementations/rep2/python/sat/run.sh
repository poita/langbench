#!/bin/sh
# Run the solver: DIMACS CNF on stdin, result on stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$DIR/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m cdcl_sat "$@"
