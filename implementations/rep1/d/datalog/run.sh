#!/bin/sh
# Run the datalog CLI: program on stdin, answers on stdout. Works from any directory.
exec "$(dirname "$0")/datalog" "$@"
