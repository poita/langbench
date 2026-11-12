#!/bin/sh
# Configure and build (Release) into ./build, from any current directory.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cmake -S "$DIR" -B "$DIR/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$DIR/build" -j 8
