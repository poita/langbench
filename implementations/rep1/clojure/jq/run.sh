#!/bin/sh
# Runs the jq-subset CLI: filter on the first stdin line, JSON document after.
DIR=$(cd "$(dirname "$0")" && pwd)
if [ -f "$DIR/target/classpath" ]; then
  exec java -XX:+UseSerialGC -Xshare:auto -XX:TieredStopAtLevel=4 \
    -cp "$(cat "$DIR/target/classpath")" jq.cli
else
  cd "$DIR" && exec clojure -M:run
fi
