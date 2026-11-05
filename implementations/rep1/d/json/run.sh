#!/bin/sh
# Run the canonjson CLI: JSON on stdin, canonical form (or "invalid") on stdout.
exec "$(dirname "$0")/bin/canonjson" "$@"
