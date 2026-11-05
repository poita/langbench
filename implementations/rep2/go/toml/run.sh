#!/bin/sh
# Run the command-line tool: reads stdin, writes stdout. Works from any directory.
exec "$(dirname "$0")/bin/toml" "$@"
