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
cd - >/dev/null

source "$ROOT/bin/base.sh"

CURRENT_VERSION="0.0.0"
if [ -f "$ROOT/VERSION" ]; then
  CURRENT_VERSION="$(cat "$ROOT/VERSION")"
fi

initArch() {
  ARCH=$(uname -m)
  case $ARCH in
    armv5*) ARCH="armv5";;
    armv6*) ARCH="armv6";;
    armv7*) ARCH="arm";;
    aarch64) ARCH="arm64";;
    x86) ARCH="386";;
    x86_64) ARCH="amd64";;
    i686) ARCH="386";;
    i386) ARCH="386";;
  esac
}

initOS() {
  OS="$(uname|tr '[:upper:]' '[:lower:]')"
  case "$OS" in
    # Minimalist GNU for Windows
    mingw*|cygwin*) OS='windows';;
  esac
}

parseArgs() {
  POSITIONAL_ARGS=()

  while [[ $# -gt 0 ]]; do
    case $1 in
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift
      ;;
    esac
  done

  set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters
}

outputWelcomeMessage() {
  echo '
 ___  ___  ___  ________  ________  _______   ________   ________
|\  \|\  \|\  \|\   ____\|\   __  \|\  ___ \ |\   ____\ |\   ____\
\ \  \\\  \ \  \ \  \___|\ \  \|\  \ \   __/|\ \  \___|_\ \  \___|_
 \ \   __  \ \  \ \  \  __\ \   _  _\ \  \_|/_\ \_____  \\ \_____  \
  \ \  \ \  \ \  \ \  \|\  \ \  \\  \\ \  \_|\ \|____|\  \\|____|\  \
   \ \__\ \__\ \__\ \_______\ \__\\ _\\ \_______\____\_\  \ ____\_\  \
    \|__|\|__|\|__|\|_______|\|__|\|__|\|_______|\_________\\_________\
                                                \|_________\|_________|
'
  echo "Higress is updated successfully."
  echo ""
  echo "If Higress is running during update, you will need to restart it to use the new version."
  echo ""
  echo "Restart command:"
  echo "  $ROOT/bin/shutdown.sh && $ROOT/bin/startup.sh"
  echo ""
  echo "Happy Higressing!"
}

update() {
  echo "Updating..."

  updateImageTags
}

updateImageTags() {
  if [ ! -f "$COMPOSE_ROOT/.env_new" ]; then
    return
  fi
  sed -i -e "/.\+_TAG=.*/d" "$COMPOSE_ROOT/.env"
  while read -r line; do
    if [[ "$line" != *"_TAG="* ]]; then
      continue
    fi
    echo "$line" >> "$COMPOSE_ROOT/.env"
  done < "$COMPOSE_ROOT/.env_new"
  rm -f "$COMPOSE_ROOT/.env_new"
}

initArch
initOS
update
outputWelcomeMessage
