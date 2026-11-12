#!/usr/bin/env bash
# Ahead-of-time compile the CLI (and the library it uses) into classes/.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf classes
mkdir -p classes
clojure -M -e "(compile 'inflate.main)"
