#!/bin/sh
# Runs the datalog tool: program on stdin, answers on stdout.
exec "$(dirname "$0")/bin/datalog" "$@"
