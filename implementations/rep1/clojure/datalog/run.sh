#!/bin/sh
# Run the Datalog engine: program on stdin, answers on stdout.
cd "$(dirname "$0")" || exit 1
exec clojure -M -m datalog.main "$@"
