#!/bin/sh
# Reads DIMACS CNF on stdin, writes the verdict (and model) on stdout.
here=$(cd "$(dirname "$0")" && pwd)
PYTHONPATH="$here/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m cdcl_sat "$@"
