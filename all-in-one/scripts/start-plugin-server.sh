#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/base.sh

if [ "$USE_PLUGIN_SERVER" != "on" ]; then
    echo "Plugin-server won't run when USE_PLUGIN_SERVER is not turned on."
    sleep 2
    exit 0
fi

# Start nginx for plugin-server (foreground mode via daemon off in nginx.conf)
exec nginx -c /etc/nginx/plugin-server/nginx.conf
