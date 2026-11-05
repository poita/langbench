#!/bin/sh
# Run the typeinfer tool: program on stdin, results on stdout.
exec "$(dirname "$0")/typeinfer" "$@"
