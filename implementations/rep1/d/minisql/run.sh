#!/bin/sh
# Runs the minisql command-line tool: SQL script on stdin, results on stdout.
exec "$(dirname "$0")/bin/minisql" "$@"
