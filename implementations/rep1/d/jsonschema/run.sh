#!/bin/sh
# Runs the jsonschema CLI: JSON document on stdin, verdicts on stdout.
exec "$(dirname "$0")/jsonschema" "$@"
