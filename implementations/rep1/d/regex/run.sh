#!/bin/sh
# Run the regex command-line tool: stdin -> stdout.
exec "$(dirname "$0")/bin/regex-cli" "$@"
