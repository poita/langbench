#!/bin/sh
# Runs the depresolve CLI: registry + root manifest on stdin, resolution on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/build/depresolve" "$@"
