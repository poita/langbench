#!/usr/bin/env bash
# Run the minisql CLI: SQL script on stdin, query results on stdout.
cd "$(dirname "$0")" || exit 1
exec clojure -M:aot -m minisql.cli "$@"
