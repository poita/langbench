#!/bin/sh
# Run depresolve: reads the registry and root manifest on stdin, writes the
# resolution on stdout.
exec "$(dirname "$0")/bin/depresolve" "$@"
