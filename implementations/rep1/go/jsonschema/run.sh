#!/bin/sh
# Run the jsonschema tool: JSON request on stdin, verdicts on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/jsonschema" "$@"
