#!/bin/sh
# Build the command-line tool (bin/toml-cli) with dub + LDC in release mode.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --config=cli --quiet
