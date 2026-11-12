#!/bin/sh
# Run the typeinfer command: program on stdin, types on stdout.
exec "$(dirname "$0")/bin/typeinfer" "$@"
