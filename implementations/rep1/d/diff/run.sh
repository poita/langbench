#!/usr/bin/env bash
# Run the diff/patch tool: reads stdin, writes stdout.
exec "$(dirname "$0")/bin/diff" "$@"
