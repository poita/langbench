#!/usr/bin/env bash
# Run the CLI: reads queries on stdin, writes results on stdout.
set -euo pipefail
cd "$(dirname "$0")"
exec clojure -M:run
