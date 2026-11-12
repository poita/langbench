#!/bin/sh
# Build the project: AOT-compile the command-line tool into target/classes.
set -e
cd "$(dirname "$0")"
rm -rf target/classes
mkdir -p target/classes
clojure -M -e "(binding [*compile-path* \"target/classes\"] (compile 'commonmark.main))"
