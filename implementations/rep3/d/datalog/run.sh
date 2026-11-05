#!/bin/sh
# Run the datalog tool: Datalog program on stdin, answers on stdout.
exec "$(dirname "$0")/bin/datalog" "$@"
