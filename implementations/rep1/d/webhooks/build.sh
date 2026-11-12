#!/bin/sh
# Builds the webhooks CLI into bin/webhooks. Works from any directory.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 "$@"
