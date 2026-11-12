#!/bin/sh
# Run the CommonMark -> HTML converter: Markdown on stdin, HTML on stdout.
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec "$ROOT/bin/commonmark" "$@"
