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
cd "$COMPOSE_ROOT" && COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose ps
