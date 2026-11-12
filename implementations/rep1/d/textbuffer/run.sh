#!/bin/sh
# Run the textbuffer CLI: reads the document and commands on stdin, writes to stdout.
exec "$(dirname "$0")/bin/textbuffer" "$@"
