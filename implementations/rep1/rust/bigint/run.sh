#!/bin/sh
# Run the CLI: reads queries on stdin, writes results on stdout.
exec "$(dirname "$0")/target/release/bigint" "$@"
