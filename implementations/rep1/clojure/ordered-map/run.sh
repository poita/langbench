#!/bin/sh
# Runs the CLI: reads commands on stdin, writes responses on stdout.
dir=$(cd "$(dirname "$0")" && pwd)
exec java -XX:+UseSerialGC -XX:TieredStopAtLevel=4 -Xshare:auto \
  -cp "$dir/target/classes:$(cat "$dir/target/classpath.txt")" ordered_map.main "$@"
