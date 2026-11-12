#!/bin/sh
# Runs the project's own test suite (Cognitect test-runner).
cd "$(dirname "$0")" && exec clojure -M:test "$@"
