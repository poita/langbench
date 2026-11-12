#!/bin/sh
# Run the commonmark command: Markdown on stdin, HTML on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/bin/commonmark" "$@"
