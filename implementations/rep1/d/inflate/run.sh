#!/bin/sh
# Run the CLI: hex DEFLATE on stdin, hex output (or "error") on stdout.
exec "$(dirname "$0")/bin/inflate-cli" "$@"
