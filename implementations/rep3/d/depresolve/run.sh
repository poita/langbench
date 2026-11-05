#!/bin/sh
# Run depresolve: reads a registry + root manifest on stdin, writes the resolution on stdout.
DIR=$(cd "$(dirname "$0")" && pwd)
exec "$DIR/depresolve" "$@"
