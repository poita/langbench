#!/usr/bin/env bash
# Run the CLI: reads the batch on stdin, writes results on stdout.
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/build/regex_cli" "$@"
