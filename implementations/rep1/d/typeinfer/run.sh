#!/bin/sh
# Run the typeinfer CLI: program on stdin, types on stdout.
exec "$(dirname "$0")/bin/typeinfer" "$@"
