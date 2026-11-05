#!/bin/sh
# Run the depresolve CLI (stdin -> stdout).
exec "$(dirname "$0")/bin/depresolve" "$@"
