#!/bin/sh
# Configures and builds minisql (Release) into <project>/build.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cmake -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$dir/build" -j 8
