#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/base.sh

if [ "$O11Y" != "on" ]; then
    echo "Promtail won't run when o11y is not turned on."
    sleep 2
    exit 0
fi

set -e

createDir /var/promtail

/usr/local/bin/promtail -config.file=/etc/promtail/promtail.yaml