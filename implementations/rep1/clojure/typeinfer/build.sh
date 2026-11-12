#!/usr/bin/env bash
# Build: AOT-compile the CLI into ./classes (works from any directory).
set -euo pipefail
cd "$(dirname "$0")"
rm -rf classes
mkdir -p classes
clojure -Sdeps '{:paths ["src" "classes"]}' -M -e "(compile 'typeinfer.main)" 2>&1 | grep -v '^Picked up' | grep -v "^typeinfer" | head -30 || true
test -f classes/typeinfer/main.class
