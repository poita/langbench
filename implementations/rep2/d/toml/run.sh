#!/bin/sh
# Run the command-line tool: reads stdin, writes stdout.
exec "$(dirname "$0")/bin/toml-cli" "$@"
