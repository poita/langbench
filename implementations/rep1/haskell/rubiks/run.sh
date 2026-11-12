#!/bin/sh
# Run the solver: scrambles on stdin, solutions on stdout.
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec "$ROOT/bin/rubiks" "$@"
