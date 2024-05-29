#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/base.sh

if [ "$MODE" != "console" -a "$MODE" != "full" ]; then
    echo "Console won't run in mode $MODE."
    sleep 2
    exit 0
fi

if [ -z "$CONSOLE_PORT" ] || [[ ! "$CONSOLE_PORT" =~ ^[0-9]+$ ]] || ((CONSOLE_PORT < 1 || CONSOLE_PORT > 65535)); then
    CONSOLE_PORT=8001
fi

echo "CONSOLE_PORT=$CONSOLE_PORT"

waitForApiServer
waitForController

touch "$CONSOLE_USED_MARKER"

set -e

HIGRESS_CONSOLE_KUBE_CONFIG="/app/kubeconfig" SERVER_PORT="$CONSOLE_PORT" \
    bash /app/start.sh