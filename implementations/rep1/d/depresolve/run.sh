#!/bin/sh
# Run depresolve: reads a registry + root manifest on stdin, writes the resolution on stdout.
exec "$(cd "$(dirname "$0")" && pwd)/bin/depresolve" "$@"
