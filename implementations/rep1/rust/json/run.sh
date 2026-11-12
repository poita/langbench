#!/bin/sh
# Run the CLI: reads a JSON document on stdin, writes its canonical form to stdout.
exec "$(dirname "$0")/target/release/json-canon" "$@"
