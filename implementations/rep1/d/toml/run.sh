#!/bin/sh
# Runs the toml tool: reads stdin, writes stdout. Works from any directory.
exec "$(dirname "$0")/bin/toml" "$@"
