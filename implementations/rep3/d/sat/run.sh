#!/bin/sh
# Run the sat command-line tool: DIMACS CNF on stdin, verdict/model on stdout.
exec "$(dirname "$0")/bin/sat" "$@"
