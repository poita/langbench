#!/bin/sh
# Configure and build the project (Release) into ./build, from any directory.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cmake -S "$here" -B "$here/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$here/build" --config Release -j 8
