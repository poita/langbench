#!/bin/sh
# Run the CLI: queries on stdin, results on stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
exec "$DIR/build/bigint_cli" "$@"
