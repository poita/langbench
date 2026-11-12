#!/bin/sh
# Configures and builds typeinfer (Release) into ./build. Works from any directory.
set -e
here=$(cd "$(dirname "$0")" && pwd)
cmake -S "$here" -B "$here/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$here/build" --config Release -j 4
