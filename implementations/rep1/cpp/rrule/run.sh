#!/bin/sh
# Run the rrule CLI: reads rules on stdin, writes occurrences on stdout.
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/build/rrule"
