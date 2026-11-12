#!/bin/sh
# Run minisql: reads SQL on stdin, writes query results on stdout.
exec "$(dirname "$0")/target/release/minisql" "$@"
