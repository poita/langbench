#!/bin/bash
# Run the CLI: reads the batch on stdin, writes results to stdout.
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/build/bin/regex" "$@"
