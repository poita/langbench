#!/bin/sh
# Run the mdiff tool: stdin -> stdout. Works from any directory.
exec "$(dirname "$0")/bin/mdiff" "$@"
