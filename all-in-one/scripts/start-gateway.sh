#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/base.sh

if [ "$MODE" != "gateway" -a "$MODE" != "full" ]; then
    echo "Gateway won't run in mode $MODE."
    sleep 2
    exit 0
fi

waitForPilot

set -e

function configureAccessLogFile() {
    local meshConfig=$1
    local o11y=$2
    local accessLogFile=

    if [ "$o11y" == "on" ]; then
        accessLogFile='/var/log/proxy/access.log'
    elif ! grep -qE '^accessLogFile:[[:space:]]*[^[:space:]]+' "$meshConfig"; then
        accessLogFile='/dev/stdout'
    fi

    if [ -z "$accessLogFile" ]; then
        return 0
    fi

    if grep -qE '^accessLogFile:' "$meshConfig"; then
        sed -i -E "s|^accessLogFile:.*$|accessLogFile: $accessLogFile|" "$meshConfig"
    else
        echo "accessLogFile: $accessLogFile" >> "$meshConfig"
    fi
}

createDir /etc/istio/proxy
createDir /var/lib/istio/data
createDir /var/log/proxy
touch /var/log/proxy/access.log

configureAccessLogFile /etc/istio/config/mesh "$O11Y"

/usr/local/bin/higress-proxy-start.sh proxy router \
    --concurrency=${GATEWAY_CONCURRENCY:-16} \
    --domain=higress-system.svc.cluster.local \
    --proxyLogLevel=${GATEWAY_LOG_LEVEL:-warning} \
    --proxyComponentLogLevel=${GATEWAY_COMPONENT_LOG_LEVEL:-misc:error} \
    --serviceCluster=higress-gateway
