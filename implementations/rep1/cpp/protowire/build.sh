#!/bin/sh
# Configure and build protowire (Release) inside this directory.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cmake -S "$DIR" -B "$DIR/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$DIR/build" --config Release -j 4
