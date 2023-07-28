#!/usr/bin/env bash

#  Copyright (c) 2023 Alibaba Group Holding Ltd.

#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at

#       http:www.apache.org/licenses/LICENSE-2.0

#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

cd "$(dirname -- "$0")"
ROOT=$(dirname -- "$(pwd -P)")
COMPOSE_ROOT="$ROOT/compose"
cd - > /dev/null

CONFIGURED_MARK="$COMPOSE_ROOT/.configured"
if [ ! -f "$CONFIGURED_MARK" ]; then
  echo "Higress hasn't been configured yet. Please run \"$ROOT/bin/configure.sh\" first"
  exit -1
fi

source "$ROOT/bin/base.sh"

source "$COMPOSE_ROOT/.env"
cd "$COMPOSE_ROOT" && COMPOSE_PROFILES="$COMPOSE_PROFILES" runDockerCompose -p higress up -d

retVal=$?
if [ $retVal -ne 0 ]; then
  echo ${1:-"  Starting Higress fails with $retVal"}
  exit $retVal
fi

echo ""
echo "Higress is now started. You can check out its status by executing $ROOT/bin/status.sh"
echo ""
echo "Higress Gateway is listening on:"
echo "  http://0.0.0.0:${GATEWAY_HTTP_PORT:-80}"
echo "  https://0.0.0.0:${GATEWAY_HTTPS_PORT:-443}"
echo "Visit Higress Console: http://localhost:${CONSOLE_PORT:-8080}/"
