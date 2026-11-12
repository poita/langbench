#!/bin/sh
# Configures and builds the project (Release) into <project>/build.
set -e
here=$(cd "$(dirname "$0")" && pwd)
cmake -S "$here" -B "$here/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$here/build" -j 8
