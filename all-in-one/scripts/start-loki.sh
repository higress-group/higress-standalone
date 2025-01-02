#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/base.sh

if [ "$O11Y" != "on" ]; then
    echo "Loki won't run when o11y is not turned on."
    sleep 2
    exit 0
fi

set -e

createDir /var/loki/chunks
createDir /var/loki/rules

/usr/local/bin/loki \
    -config.file=/etc/loki/config.yaml \
    -target=all