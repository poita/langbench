#!/bin/sh
# Ahead-of-time compile the interpreter into classes/ so run.sh starts fast.
set -e
cd "$(dirname "$0")"
mkdir -p classes
clojure -M -e "(compile 'scheme.main)"
