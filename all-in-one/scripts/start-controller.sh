#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/base.sh

waitForApiServer

set -e

/usr/local/bin/higress \
    serve \
    --kubeconfig=/app/kubeconfig \
    --gatewaySelectorKey=higress \
    --gatewaySelectorValue=higress-system-higress-gateway \
    --ingressClass=