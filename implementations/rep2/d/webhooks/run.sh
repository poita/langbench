#!/bin/sh
# Run the webhooks CLI: commands on stdin, results on stdout.
exec "$(dirname "$0")/bin/webhooks-cli" "$@"
