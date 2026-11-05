#!/bin/sh
# Run the jsonschema tool: JSON request on stdin, verdicts on stdout.
exec "$(dirname "$0")/jsonschema" "$@"
