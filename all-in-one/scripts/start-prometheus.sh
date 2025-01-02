#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/base.sh

if [ "$O11Y" != "on" ]; then
    echo "Prometheus won't run when o11y is not turned on."
    sleep 2
    exit 0
fi

set -e

createDir /prometheus

/usr/local/bin/prometheus \
      --config.file=/etc/prometheus/prometheus.yaml \
      --web.external-url=/prometheus \
      --storage.tsdb.path=/prometheus \
      --storage.tsdb.retention=6h