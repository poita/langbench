#!/bin/sh
# Run the rubiks CLI: scrambles on stdin, solutions on stdout.
exec "$(dirname "$0")/rubiks" "$@"
