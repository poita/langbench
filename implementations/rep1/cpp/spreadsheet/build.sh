#!/bin/sh
# Configure and build the project (Release) inside its own directory.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cmake -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$dir/build" --config Release -j 4
