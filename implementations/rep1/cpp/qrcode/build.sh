#!/bin/sh
# Configure and build the library, CLI and tests (Release), then run the unit tests.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cmake -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$dir/build" --config Release -j 8
if [ -z "$QRCODE_SKIP_TESTS" ]; then
  ctest --test-dir "$dir/build" -C Release --output-on-failure
fi
