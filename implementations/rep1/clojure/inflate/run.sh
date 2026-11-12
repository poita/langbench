#!/usr/bin/env bash
# Read a hex-encoded raw DEFLATE stream on stdin; write the hex-encoded result
# (or the word "error") on stdout.
cd "$(dirname "$0")" || exit 1
exec clojure -M -m inflate.main "$@"
