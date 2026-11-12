#!/bin/sh
# Builds the minisql command-line tool into bin/minisql.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --quiet
