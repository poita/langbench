#!/bin/sh
# Run depresolve: reads the registry + root manifest on stdin, writes the resolution on stdout.
exec "$(dirname "$0")/depresolve" "$@"
