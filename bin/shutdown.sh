#! /bin/bash

ROOT=$(dirname $(dirname "$(readlink -f "$0")"))
COMPOSE_ROOT="$ROOT/compose"
cd "$COMPOSE_ROOT" && docker compose down --remove-orphans
