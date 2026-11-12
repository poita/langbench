#!/bin/sh
# Run the bigint tool: queries on stdin, answers on stdout.
exec "$(dirname "$0")/bin/bigint" "$@"
