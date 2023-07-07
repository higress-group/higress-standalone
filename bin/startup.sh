#! /bin/bash

cd "$(dirname -- "$0")"
ROOT=$(dirname -- "$(pwd -P)")
COMPOSE_ROOT="$ROOT/compose"
cd - > /dev/null

CONFIGURED_MARK="$COMPOSE_ROOT/.configured"
if [ ! -f "$CONFIGURED_MARK" ]; then
  echo "Higress hasn't been configured yet. Please run \"$ROOT/bin/configure.sh\" first"
  exit -1
fi
cd "$COMPOSE_ROOT" && COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose up -d

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