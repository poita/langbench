#!/usr/bin/env bash
# Run hjq: filter on the first stdin line, JSON document on the rest.
exec "$(dirname "$0")/bin/hjq" "$@"
