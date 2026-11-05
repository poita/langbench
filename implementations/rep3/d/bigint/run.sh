#!/bin/sh
# Run the bigint tool: queries on stdin, results on stdout.
exec "$(dirname "$0")/bin/bigint" "$@"
