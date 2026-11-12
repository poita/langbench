#!/bin/sh
# Run the validator: JSON request on stdin, one `valid`/`invalid` line per test on stdout.
exec "$(dirname "$0")/target/release/jsonschema-cli" "$@"
