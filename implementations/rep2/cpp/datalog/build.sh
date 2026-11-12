#!/bin/sh
# Builds the library, the CLI and the unit tests (Release) into ./build.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
cmake -S "$here" -B "$here/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$here/build" -j 4
