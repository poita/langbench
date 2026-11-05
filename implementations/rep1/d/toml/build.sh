#!/bin/sh
# Build the toml command-line tool (bin/toml-cli).
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
exec dub build -b release --compiler=ldc2 --config=cli --quiet
