#!/bin/sh
# Run langvm: reads a Vellum module stream on stdin, writes the result to stdout.
exec "$(dirname "$0")/bin/langvm" "$@"
