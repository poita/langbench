#!/bin/sh
# Run the depresolve CLI: reads a registry + root manifest on stdin.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/depresolve" "$@"
