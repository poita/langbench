#!/bin/sh
# Build the project: AOT-compile the command-line tool into ./classes.
set -e
cd "$(dirname "$0")"
rm -rf classes
mkdir classes
clojure -M -e "(compile 'datalog.main)"
