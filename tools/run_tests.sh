#!/bin/sh
# Runs the host-side tests for the compatibility shims and native bridges.
#
# The shims and bridge are pure C++ over libc and run on the host.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
COMPAT_OUT=${TMPDIR:-/tmp}/swshell-compat-test
SSH_OUT=${TMPDIR:-/tmp}/swshell-ssh-protocol-test
DSH_OUT=${TMPDIR:-/tmp}/swshell-dsh-bridge-test
DISCOVERY_OUT=${TMPDIR:-/tmp}/swshell-discovery-test

clang++ -std=c++17 -Wall -Wextra \
    -I "$ROOT/entry/src/main/cpp/compat" \
    "$ROOT/entry/src/main/cpp/test/compat_test.cpp" \
    -o "$COMPAT_OUT"

clang++ -std=c++17 -Wall -Wextra -Werror \
    -I "$ROOT/entry/src/main/cpp" \
    "$ROOT/entry/src/main/cpp/ssh_protocol.cpp" \
    "$ROOT/entry/src/main/cpp/test/ssh_protocol_test.cpp" \
    -o "$SSH_OUT"

clang++ -std=c++17 -Wall -Wextra -pthread \
    -I "$ROOT/entry/src/main/cpp" \
    "$ROOT/entry/src/main/cpp/dsh_host.cpp" \
    "$ROOT/entry/src/main/cpp/test/dsh_bridge_test.cpp" \
    -o "$DSH_OUT"

clang++ -std=c++17 -Wall -Wextra -Werror \
    -I "$ROOT/entry/src/main/cpp" \
    "$ROOT/entry/src/main/cpp/discovery.cpp" \
    "$ROOT/entry/src/main/cpp/test/discovery_test.cpp" \
    -o "$DISCOVERY_OUT"

RC=0
"$SSH_OUT" || RC=$?
"$COMPAT_OUT" || RC=$?
"$DSH_OUT" || RC=$?
"$DISCOVERY_OUT" || RC=$?
exit $RC
