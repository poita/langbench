#!/bin/sh
# Run the spreadsheet CLI: commands on stdin, results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/spreadsheet" "$@"
