#!/bin/sh
# Run the rrule command-line tool: reads rules on stdin, writes occurrences on stdout.
exec "$(dirname "$0")/rrule" "$@"
