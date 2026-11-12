#!/bin/sh
# Run the CommonMark -> HTML converter: Markdown on stdin, HTML on stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
cd "$dir"
exec clojure -M -m commonmark.main "$@"
