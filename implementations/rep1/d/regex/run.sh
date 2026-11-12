#!/bin/sh
# Run the btregex CLI: reads the batch format on stdin, writes results to stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
exec "$DIR/bin/btregex" "$@"
