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

if [ -n "$CONFIG_TEMPLATE" ]; then
    TEMPLATE_SCRIPT="$ROOT/config-template/$CONFIG_TEMPLATE.sh"
    if [ -f "$TEMPLATE_SCRIPT" ]; then
        /bin/bash "$TEMPLATE_SCRIPT"
    else
        echo "Unknown config template: $CONFIG_TEMPLATE"
        exit 1
    fi
fi

apiserver --bind-address 127.0.0.1 --secure-port 18443 --storage file --file-root-dir /data --cert-dir /tmp