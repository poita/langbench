#!/bin/sh
# Runs the spreadsheet CLI: commands on stdin, results on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec java -cp "$dir/classes:$(cat "$dir/.classpath")" spreadsheet.main "$@"
