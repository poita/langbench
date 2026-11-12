#!/bin/sh
# Configure and build (Release) into ./build, from any current directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cmake -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$dir/build" --config Release -j 4
