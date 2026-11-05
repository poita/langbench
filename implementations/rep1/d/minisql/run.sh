#!/bin/sh
# Run minisql: SQL script on stdin, query results on stdout.
exec "$(dirname "$0")/bin/minisql" "$@"
