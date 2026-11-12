#!/bin/sh
# Run the converter: Markdown on stdin, HTML on stdout.
# Works from any current directory.
dir=$(cd "$(dirname "$0")" && pwd)
exec "$dir/target/release/commonmark" "$@"
