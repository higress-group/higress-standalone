#!/usr/bin/env bash

#  Copyright (c) 2024 Alibaba Group Holding Ltd.

#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at

#       http:www.apache.org/licenses/LICENSE-2.0

#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

DOCKER_COMMAND="docker"

HAS_DOCKER="$(type "docker" &>/dev/null && echo true || echo false)"
if [ "${HAS_DOCKER}" != "true" ]; then
  echo "Docker is required"
  exit 1
fi

DEFAULT_CONTAINER_NAME=higress
DEFAULT_IMAGE_REPO=higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/all-in-one
# DFEAULT_IMAGE_TAG=latest
DFEAULT_IMAGE_TAG=20241029
DEFAULT_GATEWAY_HTTP_PORT=8080
DEFAULT_GATEWAY_HTTPS_PORT=8443
DEFAULT_CONSOLE_PORT=8001

CONFIG_FILENAME="default.cfg"

COMMAND_START="start"
COMMAND_STOP="stop"
KNOWN_COMMANDS=($COMMAND_START, $COMMAND_STOP)

cd "$(dirname -- "$0")"
ROOT="$(pwd -P)/higress"
cd - >/dev/null

CONFIGURED_MARK="$ROOT/.configured"

initArch() {
  ARCH=$(uname -m)
  case $ARCH in
  armv5*) ARCH="armv5" ;;
  armv6*) ARCH="armv6" ;;
  armv7*) ARCH="arm" ;;
  aarch64) ARCH="arm64" ;;
  x86) ARCH="386" ;;
  x86_64) ARCH="amd64" ;;
  i686) ARCH="386" ;;
  i386) ARCH="386" ;;
  esac
}

initOS() {
  OS="$(uname | tr '[:upper:]' '[:lower:]')"
  case "$OS" in
  # Minimalist GNU for Windows
  mingw* | cygwin*) OS='windows' ;;
  esac
}

normalizePath() {
  if [ "$OS" != "windows" ]; then
    echo "$1"
    return
  fi
  echo "$(cygpath -m "$1")"
}

parseArgs() {
  resetEnv

  POSITIONAL_ARGS=()

  COMMAND=""
  MODE="wizard"

  if [[ $1 != "-"* ]]; then
    COMMAND="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case $1 in
    -h | --help)
      outputUsage
      exit 0
      ;;
    -* | --*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift
      ;;
    esac
  done

  set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

  if [ -z "$COMMAND" ]; then
    COMMAND=$COMMAND_START
  fi
  if [[ ! ${KNOWN_COMMANDS[@]} =~ "$COMMAND" ]]; then
    echo "Unknown command: $COMMAND"
    exit 1
  fi
}

configure() {
  if [ "$MODE" == "wizard" ]; then
    runConfigWizard
  fi

  configureStorage
  writeConfiguration
}

resetEnv() {
  DATA_FOLDER="$ROOT"
  CONTAINER_NAME="$DEFAULT_CONTAINER_NAME"

  IMAGE_REPO="$DEFAULT_IMAGE_REPO"
  IMAGE_TAG="$DFEAULT_IMAGE_TAG"

  GATEWAY_HTTP_PORT="$DEFAULT_GATEWAY_HTTP_PORT"
  GATEWAY_HTTPS_PORT="$DEFAULT_GATEWAY_HTTPS_PORT"
  CONSOLE_PORT="$DEFAULT_CONSOLE_PORT"
}

runConfigWizard() {
  echo "Provide a key for each LLM provider you want to enable, then press Enter."
  echo "If no key is provided and Enter is pressed, configuration for that provider will be skipped."

  echo

  read -r -p "→ Enter API Key for OpenAI: " OPENAI_API_KEY
  read -r -p "→ Enter API Key for Aliyun Dashscope: " DASHSCOPE_API_KEY
  read -r -p "→ Enter API Key for Moonshot: " MOONSHOT_API_KEY

  echo
}

configureStorage() {
  if [ -d "$DATA_FOLDER" ]; then
    return 0
  fi
  mkdir -p "$DATA_FOLDER"
  if [ $? -ne 0 ]; then
    echo "Unable to create/access the data folder: $DATA_FOLDER"
    continue
  fi
}

writeConfiguration() {
  cat <<EOF >$DATA_FOLDER/$CONFIG_FILENAME
MODE=full
CONFIG_TEMPLATE=ai-gateway
DASHSCOPE_API_KEY=${DASHSCOPE_API_KEY}
MOONSHOT_API_KEY=${MOONSHOT_API_KEY}
OPENAI_API_KEY=${OPENAI_API_KEY}
GATEWAY_HTTP_PORT=${GATEWAY_HTTP_PORT}
GATEWAY_HTTPS_PORT=${GATEWAY_HTTPS_PORT}
CONSOLE_PORT=${CONSOLE_PORT}
EOF
}

outputUsage() {
  echo -n "Usage: $(basename -- "$0") [OPTIONS...]"
  echo '
 -h, --help                 give this help list'
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
  echo "Higress AI Gateway is started successfully."

  echo
  echo "======================================================="
  echo "               Using Higress AI Gateway                "
  echo "======================================================="
  echo
  echo "Higress AI Gateway Data Plane endpoints:"
  echo "    HTTP  = http://localhost:$GATEWAY_HTTP_PORT"
  echo "    HTTPS = https://localhost:$GATEWAY_HTTPS_PORT}"
  echo
  echo "Higress AI Gateway chat completion endpoint:"
  echo "    http://localhost:$GATEWAY_HTTP_PORT/v1/chat/completions"
  echo
  echo "You can try it with cURL directly:"
  echo "    curl 'http://localhost:$GATEWAY_HTTP_PORT/v1/chat/completions' \\"
  echo "      -H 'Content-Type: application/json' \\"
  echo "      -d '{"
  echo "        \"model\": \"aliyun/qwen-turbo\","
  echo '        "messages": ['
  echo "          {"
  echo '            "role": "user",'
  echo '            "content": "Hello!"'
  echo "          }"
  echo "        ]"
  echo "      }'"

  echo
  echo "======================================================="
  echo "             Administer Higress AI Gateway             "
  echo "======================================================="
  echo
  echo "Higress Console URL (open with browser):"
  echo "   http://localhost:$CONSOLE_PORT"

  echo
  echo "To stop the gateway run:"
  echo
  echo "  $DOCKER_COMMAND stop $CONTAINER_NAME"

  echo
  echo "Happy Higressing!"
}

start() {
  echo "Starting Higress AI Gateway..."
  echo

  NORMALIZED_DATA_FOLDER_PATH="$(normalizePath "${DATA_FOLDER}")"
  NORMALIZED_CONFIG_FILE_PATH="$(normalizePath "${DATA_FOLDER}/${CONFIG_FILENAME}")"

  $DOCKER_COMMAND run --name higress -d --rm \
    -p 127.0.0.1:$GATEWAY_HTTP_PORT:8080 \
    -p 127.0.0.1:$GATEWAY_HTTPS_PORT:8443 \
    -p 127.0.0.1:$CONSOLE_PORT:8001 \
    --env-file "$NORMALIZED_CONFIG_FILE_PATH" \
    --mount "type=bind,source=$NORMALIZED_DATA_FOLDER_PATH,target=/data" "$IMAGE_REPO:$IMAGE_TAG" >/dev/null

  if [ $? -eq 0 ]; then
    outputWelcomeMessage
  fi
}

stop() {
  echo "Stopping Higress AI Gateway..."
  echo

  $DOCKER_COMMAND stop $CONTAINER_NAME >/dev/null

  if [ $? -eq 0 ]; then
    echo "Thanks for using Higress AI Gateway."
  fi
}

initArch
initOS
parseArgs "$@"
case $COMMAND in
"$COMMAND_START")
  if [ ! -f "$CONFIGURED_MARK" ]; then
    configure
    touch "$CONFIGURED_MARK"
  fi
  start
  ;;
"$COMMAND_STOP")
  stop
  ;;
esac
