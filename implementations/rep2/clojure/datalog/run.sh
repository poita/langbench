#!/usr/bin/env bash
# Run the CLI: reads a Datalog program on stdin, writes query answers to stdout.
cd "$(dirname "$0")" || exit 1
exec clojure -M:run
