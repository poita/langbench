#!/bin/sh
# Configure and build gitrepo (Release) into ./build, wherever it is run from.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cmake -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$dir/build" --parallel
