#!/bin/sh
# Runs langvm: Vellum program on stdin, output on stdout. Works from any directory.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/langvm" "$@"
