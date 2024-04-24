#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/base.sh

if [ -z "$GATEWAY_HTTP_PORT" ] || [[ ! "$GATEWAY_HTTP_PORT" =~ ^[0-9]+$ ]] || ((GATEWAY_HTTP_PORT < 1 || GATEWAY_HTTP_PORT > 65535)); then
    GATEWAY_HTTP_PORT=8080
fi
if [ -z "$GATEWAY_HTTPS_PORT" ] || [[ ! "$GATEWAY_HTTPS_PORT" =~ ^[0-9]+$ ]] || ((GATEWAY_HTTPS_PORT < 1 || GATEWAY_HTTPS_PORT > 65535)); then
    GATEWAY_HTTPS_PORT=8443
fi

echo "GATEWAY_HTTP_PORT=$GATEWAY_HTTP_PORT"
echo "GATEWAY_HTTPS_PORT=$GATEWAY_HTTPS_PORT"

waitForApiServer

set -e

/usr/local/bin/higress \
    serve \
    --kubeconfig=/app/kubeconfig \
    --gatewaySelectorKey=higress \
    --gatewaySelectorValue=higress-system-higress-gateway \
    --gatewayHttpPort=$GATEWAY_HTTP_PORT \
    --gatewayHttpsPort=$GATEWAY_HTTPS_PORT \
    --ingressClass=