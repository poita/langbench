#!/bin/sh
# Build the commonmark command-line tool (bin/commonmark).
set -e
cd "$(dirname "$0")"
for d in "$HOME/dlang/ldc-1.41.0/bin"; do
    [ -d "$d" ] && PATH="$d:$PATH"
done
export PATH
exec dub build -b release --compiler=ldc2 --quiet
