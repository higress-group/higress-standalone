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

MESH_CONFIG_DIR='/etc/istio/config'
mkdir -p $MESH_CONFIG_DIR
HIGRESS_CONFIG_FILE="/data/configmaps/higress-config.yaml"
MESH_CONFIG_FILES=$(yq '.data | keys | .[]' "$HIGRESS_CONFIG_FILE")
if [ -z "$MESH_CONFIG_FILES" ]; then
    echo "  Missing required files in higress-config ConfigMap."
    exit -1
fi
IFS=$'\n'
for MESH_CONFIG_FILE in $MESH_CONFIG_FILES; do
    if [ -z "$MESH_CONFIG_FILE" -o "$MESH_CONFIG_FILE" == "higress" ]; then
        continue
    fi
    yq ".data.$MESH_CONFIG_FILE" "$HIGRESS_CONFIG_FILE" > "$MESH_CONFIG_DIR/$MESH_CONFIG_FILE"
done

apiserver --bind-address 127.0.0.1 --secure-port 18443 --storage file --file-root-dir /data --cert-dir /tmp