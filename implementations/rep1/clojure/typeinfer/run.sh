#!/usr/bin/env bash
# Run the CLI: program on stdin, report on stdout (works from any directory).
cd "$(dirname "$0")" || exit 1
exec clojure -Sdeps '{:paths ["classes" "src"]}' -M -m typeinfer.main "$@"
