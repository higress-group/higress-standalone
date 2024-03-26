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

waitForApiServer
waitForController

set -e

HIGRESS_CONSOLE_KUBE_CONFIG="/app/kubeconfig" \
    bash /app/start.sh