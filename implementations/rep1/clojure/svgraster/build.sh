#!/bin/sh
# Resolve dependencies and AOT-compile the command-line tool into classes/
# (this only speeds up start-up; run.sh also works from plain sources).
set -e
cd "$(dirname "$0")"
mkdir -p classes
clojure -M -e "(compile 'svgraster.main)"
