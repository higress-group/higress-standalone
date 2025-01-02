#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/base.sh

if [ "$O11Y" != "on" ]; then
    echo "Grafana won't run when o11y is not turned on."
    sleep 2
    exit 0
fi

set -e

createDir /var/lib/grafana
createDir /var/log/grafana

GF_PATHS_CONFIG="/etc/grafana/grafana.ini" \
    GF_PATHS_DATA="/var/lib/grafana" \
    GF_PATHS_HOME="/usr/share/grafana" \
    GF_PATHS_LOGS="/var/log/grafana" \
    GF_PATHS_PLUGINS="/var/lib/grafana/plugins" \
    GF_PATHS_PROVISIONING="/etc/grafana/provisioning" \
    PATH="/usr/share/grafana/bin:$PATH" \
    bash /usr/local/bin/grafana.sh