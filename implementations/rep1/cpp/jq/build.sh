#!/bin/sh
# Configures and builds the project (Release) into ./build.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cmake -S "$DIR" -B "$DIR/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$DIR/build" --config Release -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
