#!/bin/sh
# Run the webhooks CLI: reads commands on stdin, writes results on stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$dir/.cp" ]; then
  cp="$(cat "$dir/.cp")"
  # .cp holds paths relative to the project directory
  cd "$dir"
  exec java -cp "$cp" webhooks.cli "$@"
else
  cd "$dir"
  exec clojure -M:build -m webhooks.cli "$@"
fi
