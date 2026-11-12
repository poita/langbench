#!/bin/sh
# Run the template command: JSON context and templates on stdin, result on stdout.
exec "$(dirname "$0")/bin/template" "$@"
