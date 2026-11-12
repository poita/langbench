#!/bin/sh
# Run the solver: scrambles on stdin, solutions on stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
exec "$DIR/build/rubiks" "$@"
