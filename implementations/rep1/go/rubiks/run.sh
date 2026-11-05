#!/bin/sh
# Run the rubiks solver: scrambles on stdin, solutions on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/rubiks" "$@"
