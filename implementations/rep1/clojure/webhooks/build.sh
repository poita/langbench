#!/bin/sh
# Build the project: AOT-compile the CLI into classes/ and record the classpath.
set -e
cd "$(dirname "$0")"
mkdir -p classes
clojure -M:build -e "(compile 'webhooks.cli)"
clojure -A:build -Spath > .cp
