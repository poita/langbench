#!/bin/sh
# Run the solver: scrambles on stdin, solutions on stdout.
cd "$(dirname "$0")" || exit 1
exec clojure -M -m rubiks.cli "$@"
