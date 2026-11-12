#!/usr/bin/env bash
# Run the regex tool: reads the problem on stdin, writes results to stdout.
cd "$(dirname "$0")" || exit 1
exec clojure -J-XX:+UseSerialGC -J-Xshare:auto -J-XX:TieredStopAtLevel=4 -M:run "$@"
