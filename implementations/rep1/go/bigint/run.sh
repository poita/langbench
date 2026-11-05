#!/bin/sh
# Runs the bigint command-line tool: queries on stdin, results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/bigint" "$@"
