#!/bin/sh
# Runs the converter: Markdown on stdin, HTML on stdout.
exec "$(dirname "$0")/bin/commonmark" "$@"
