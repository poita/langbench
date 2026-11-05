#!/bin/sh
# Runs the toml command-line tool (stdin -> stdout).
exec "$(dirname "$0")/bin/toml" "$@"
