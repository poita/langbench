#!/bin/sh
# Build the toml command-line tool into bin/toml.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --quiet
