#!/bin/sh
# Run the jsoncanon CLI: stdin -> stdout. Works from any directory.
exec "$(dirname "$0")/jsoncanon" "$@"
