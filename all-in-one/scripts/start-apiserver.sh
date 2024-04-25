#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/base.sh

set -e

if [ "$ENABLE_CONSOLE_ROUTE" != "1" ]; then
    sudo rm -f /opt/data/defaultConfig/ingresses/higress-console.yaml
fi
cp -rn /opt/data/defaultConfig/* /data

apiserver --bind-address 127.0.0.1 --secure-port 18443 --storage file --file-root-dir /data --cert-dir /tmp