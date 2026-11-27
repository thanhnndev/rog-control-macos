#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Tests AsusWmi's fan-curve checks in userspace (no kext load, no hardware writes).
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
{
    printf '#include <stdint.h>\n'
    sed -n '/CURVE-CHECKS-BEGIN/,/CURVE-CHECKS-END/p' kexts/AsusWmi/AsusWmi.cpp
    cat test/asuswmi_curve_test.cpp
} > "$TEST_DIR/main.cpp"
clang++ -std=c++17 -Wall -Wextra -Werror "$TEST_DIR/main.cpp" -o "$TEST_DIR/curve-tests"
"$TEST_DIR/curve-tests"
