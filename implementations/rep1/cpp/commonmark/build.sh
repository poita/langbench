#!/bin/sh
# Builds the library, the CLI and the unit tests (Release) into ./build.
set -e
root=$(cd "$(dirname "$0")" && pwd)
cmake -S "$root" -B "$root/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$root/build" --config Release -j 4
