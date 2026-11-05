#!/bin/sh
# Run the spreadsheet CLI: commands on stdin, results on stdout.
exec "$(dirname "$0")/bin/spreadsheet" "$@"
