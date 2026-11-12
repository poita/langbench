#!/bin/sh
# Run the rrule CLI: stdin -> stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$dir/target/classpath" ]; then
  exec java -cp "$(cat "$dir/target/classpath")" rrule.cli
else
  cd "$dir" && exec clojure -M -m rrule.cli
fi
