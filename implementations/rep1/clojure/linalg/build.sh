#!/bin/sh
# Build linalg: AOT-compile the command-line tool into classes/.
set -e
cd "$(dirname "$0")"
rm -rf classes
mkdir -p classes
clojure -M -e "(compile 'linalg.cli)"
