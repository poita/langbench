#!/usr/bin/env bash
# Builds depresolve: AOT-compiles the CLI into target/classes for fast startup.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf target/classes
mkdir -p target/classes
clojure -J-Dclojure.compile.path=target/classes -M -e "(compile 'depresolve.cli)"
