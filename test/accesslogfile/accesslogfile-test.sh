#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd -P)
START_GATEWAY_SCRIPT="$ROOT/all-in-one/scripts/start-gateway.sh"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

FUNCTION_FILE="$WORK_DIR/configureAccessLogFile.sh"
sed -n '/^function configureAccessLogFile() {/,/^}/p' "$START_GATEWAY_SCRIPT" > "$FUNCTION_FILE"
if [ ! -s "$FUNCTION_FILE" ]; then
    echo "ERROR: failed to extract configureAccessLogFile from $START_GATEWAY_SCRIPT" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$FUNCTION_FILE"

FAILURES=0

writeMeshConfig() {
    local meshConfig=$1
    local accessLogFileLine=${2-}
    {
        echo 'accessLogEncoding: TEXT'
        if [ -n "$accessLogFileLine" ]; then
            echo "$accessLogFileLine"
        fi
        echo 'accessLogFormat: |'
        echo '  {}'
    } > "$meshConfig"
}

assertAccessLogFile() {
    local meshConfig=$1
    local expected=$2
    local caseName=$3
    local count actual
    count=$(grep -cE '^accessLogFile:' "$meshConfig" || true)
    actual=$(sed -nE 's/^accessLogFile:[[:space:]]*(.*)$/\1/p' "$meshConfig" | head -n 1)
    if [ "$count" != "1" ] || [ "$actual" != "$expected" ]; then
        echo "FAIL: $caseName (expected one line with '$expected', got $count line(s) with '$actual')" >&2
        FAILURES=$((FAILURES + 1))
    else
        echo "PASS: $caseName"
    fi
}

# (a) O11Y=off with an explicit accessLogFile must preserve the configured value.
MESH_CONFIG="$WORK_DIR/mesh-explicit"
writeMeshConfig "$MESH_CONFIG" 'accessLogFile: /var/log/higress/custom-access.log'
configureAccessLogFile "$MESH_CONFIG" off
assertAccessLogFile "$MESH_CONFIG" '/var/log/higress/custom-access.log' \
    'O11Y=off preserves explicit accessLogFile'

# (b) O11Y=off without an explicit value must apply the default.
MESH_CONFIG="$WORK_DIR/mesh-missing"
writeMeshConfig "$MESH_CONFIG"
configureAccessLogFile "$MESH_CONFIG" off
assertAccessLogFile "$MESH_CONFIG" '/dev/stdout' \
    'O11Y=off applies default when accessLogFile is absent'

MESH_CONFIG="$WORK_DIR/mesh-empty"
writeMeshConfig "$MESH_CONFIG" 'accessLogFile:'
configureAccessLogFile "$MESH_CONFIG" off
assertAccessLogFile "$MESH_CONFIG" '/dev/stdout' \
    'O11Y=off applies default when accessLogFile is empty'

# (c) O11Y=on must still apply the O11Y preset as before.
MESH_CONFIG="$WORK_DIR/mesh-o11y"
writeMeshConfig "$MESH_CONFIG" 'accessLogFile: /dev/stdout'
configureAccessLogFile "$MESH_CONFIG" on
assertAccessLogFile "$MESH_CONFIG" '/var/log/proxy/access.log' \
    'O11Y=on applies O11Y preset'

MESH_CONFIG="$WORK_DIR/mesh-o11y-explicit"
writeMeshConfig "$MESH_CONFIG" 'accessLogFile: /var/log/higress/custom-access.log'
configureAccessLogFile "$MESH_CONFIG" on
assertAccessLogFile "$MESH_CONFIG" '/var/log/proxy/access.log' \
    'O11Y=on applies O11Y preset over explicit value (unchanged behavior)'

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES accessLogFile test(s) failed" >&2
    exit 1
fi
echo 'All accessLogFile tests passed'
