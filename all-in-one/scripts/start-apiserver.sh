#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/base.sh

set -e

cp -rn /opt/data/defaultConfig/* /data

apiserver --bind-address 127.0.0.1 --secure-port 8443 --storage file --file-root-dir /data --cert-dir /tmp