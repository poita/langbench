#!/bin/sh
# Run the inflate command (stdin -> stdout). Works from any directory.
exec "$(dirname "$0")/bin/inflate" "$@"
