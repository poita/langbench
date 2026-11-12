#!/bin/sh
# Run the CLI: queries on stdin, results on stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
exec "$dir/target/release/bigint" "$@"
