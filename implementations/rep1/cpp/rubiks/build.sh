#!/bin/sh
# Configure and build the project (Release) in ./build, from any directory.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
cmake -S "$DIR" -B "$DIR/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$DIR/build" --config Release -j 4
