#!/bin/sh
# Run the toml CLI: mode line + document on stdin, result on stdout.
exec "$(dirname "$0")/toml" "$@"
