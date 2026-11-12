#!/bin/sh
# Build the orderbook CLI (bin/orderbook) with dub + LDC in release mode.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --config=cli
