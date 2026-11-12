#!/bin/sh
# Configures and builds depresolve (Release) in ./build; works from any directory.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cmake -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$dir/build" --config Release -j 4
