#!/bin/sh
# Build the webhooks CLI (bin/webhooks-cli) with dub + LDC.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --quiet
