#!/bin/sh
# Run the rrule CLI: reads rules on stdin, writes occurrences on stdout.
exec "$(dirname "$0")/target/release/rrule" "$@"
