#!/bin/sh
# Run the datalog tool: Datalog program on stdin, query answers on stdout.
exec "$(dirname "$0")/bin/datalog" "$@"
