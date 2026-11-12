#!/bin/sh
# Runs the langvm CLI: reads a module stream on stdin, writes the result to stdout.
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/build/langvm" "$@"
