#!/bin/sh
# Configures and builds the project (Release) into ./build. Works from any directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cmake -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$dir/build" -j 8
