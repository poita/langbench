#!/bin/sh
# Runs the command-line tool: reads the problem document on stdin, writes verdicts to stdout.
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/build/jsonschema-cli" "$@"
