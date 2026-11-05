#!/bin/sh
# Run depresolve: reads a registry + root manifest on stdin, writes the
# resolution on stdout.
exec "$(dirname "$0")/bin/depresolve" "$@"
