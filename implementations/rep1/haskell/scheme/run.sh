#!/bin/sh
# Run the interpreter: program on stdin, output on stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
exec "$DIR/bin/scheme" "$@"
