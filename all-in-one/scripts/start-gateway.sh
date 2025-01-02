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

createDir /etc/istio/proxy
createDir /var/lib/istio/data
createDir /var/log/proxy
touch /var/log/proxy/access.log

if [ "$O11Y" == "on" ]; then
    sed -i -E 's/^accessLogFile: .+$/accessLogFile: \/var\/log\/proxy\/access.log/' /etc/istio/config/mesh
else
    sed -i -E 's/^accessLogFile: .+$/accessLogFile: \/dev\/stdout/' /etc/istio/config/mesh
fi

/usr/local/bin/higress-proxy-start.sh proxy router \
    --domain=higress-system.svc.cluster.local \
    --proxyLogLevel=${GATEWAY_LOG_LEVEL:-warning} \
    --proxyComponentLogLevel=${GATEWAY_COMPONENT_LOG_LEVEL:-misc:error} \
    --log_output_level=all:info \
    --serviceCluster=higress-gateway