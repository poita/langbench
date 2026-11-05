#!/bin/sh
# Run the bigint command-line tool: queries on stdin, results on stdout.
exec "$(dirname "$0")/bigint-cli" "$@"
