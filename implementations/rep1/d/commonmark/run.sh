#!/bin/sh
# Run the commonmark tool: Markdown on stdin, HTML on stdout.
exec "$(dirname "$0")/bin/commonmark" "$@"
