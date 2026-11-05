#!/bin/sh
# Run the regex command (stdin -> stdout). Works from any directory.
exec "$(dirname "$0")/bin/regex" "$@"
