#!/bin/sh
# Run the CLI: queries on stdin, answers on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/chess-perft" "$@"
