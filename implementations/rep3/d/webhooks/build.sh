#!/bin/sh
# Build the webhooks CLI (bin/webhooks) with dub + LDC. Works from any directory.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
