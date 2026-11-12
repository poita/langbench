#!/bin/sh
# Run the emulator: input on stdin, report on stdout.
dir="$(cd "$(dirname "$0")" && pwd)"
cd "$dir" || exit 1
exec clojure -M:compile:run
