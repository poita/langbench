#!/usr/bin/env bash
# Runs the depresolve CLI: reads a registry + root manifest on stdin,
# writes the resolution on stdout.
set -euo pipefail
cd "$(dirname "$0")"
exec clojure -M -m depresolve.cli "$@"
