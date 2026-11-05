#!/bin/sh
# Run the bigint CLI: queries on stdin, results on stdout.
exec "$(dirname "$0")/bin/bigint" "$@"
