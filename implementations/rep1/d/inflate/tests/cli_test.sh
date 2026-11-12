#!/bin/sh
# End-to-end checks of the CLI contract. Run after ./build.sh.
dir=$(cd "$(dirname "$0")/.." && pwd)
fail=0
check() { # input expected
    got=$(printf '%s\n' "$1" | "$dir/run.sh")
    if [ "$got" != "$2" ]; then
        echo "FAIL: input '$1' expected '$2' got '$got'"
        fail=1
    fi
}
check "0300" ""
check "010100feff41" "41"
check "4b4c4a862000" "616263616263616263"
check "030200" "error"
check "" "error"
check "0300ff" "error"
[ $fail = 0 ] && echo "cli tests passed"
exit $fail
