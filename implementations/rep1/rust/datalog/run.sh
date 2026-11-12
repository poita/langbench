#!/bin/sh
# Run the datalog CLI: program on stdin, answers on stdout.
exec "$(dirname "$0")/target/release/datalog" "$@"
