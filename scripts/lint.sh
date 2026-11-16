#!/bin/zsh
# Style checks: the 4 pt grid, colors and fonts only through the design kit, no shell strings.
set -u
cd ${0:A:h:h}
fail=0
tools/grid-lint.sh | tail -3 || fail=1
echo "== raw colors, fonts, or symbols outside the design kit"
grep -rnE 'Color\(hex|Color\(red' Sources/ForgeDeck | grep -v DesignKit/ && fail=1
echo "== shell invocations (must be empty)"
grep -rnE '"sh", "-c"|/bin/sh|/bin/bash|sh -c' Sources | grep -v "SelfTest.swift" && fail=1
echo "== StrictHostKeyChecking=no (must be empty)"
grep -rn 'StrictHostKeyChecking=no' Sources && fail=1
[[ $fail == 0 ]] && echo "PASS lint" || echo "FAIL lint"
exit $fail
