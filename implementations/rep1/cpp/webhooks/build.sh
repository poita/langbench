#!/bin/sh
# Builds the library, the CLI and the unit tests (Release) into ./build.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
cmake -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$dir/build" --config Release -j 8
