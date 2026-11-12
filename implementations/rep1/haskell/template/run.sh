#!/bin/sh
# Run the template CLI: JSON context + templates on stdin, result on stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
exec "$dir/bin/template" "$@"
