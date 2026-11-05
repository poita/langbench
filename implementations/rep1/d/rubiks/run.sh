#!/bin/sh
# Run the solver: scrambles on stdin, solutions on stdout.
exec "$(dirname "$0")/bin/rubiks" "$@"
