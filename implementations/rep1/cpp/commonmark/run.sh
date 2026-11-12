#!/bin/sh
# Converts Markdown on stdin to HTML on stdout.
root=$(cd "$(dirname "$0")" && pwd)
exec "$root/build/commonmark-cli" "$@"
