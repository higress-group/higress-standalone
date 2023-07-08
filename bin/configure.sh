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

BUILTIN_NACOS_SERVER_URL=nacos://nacos:8848
DEFAULT_NACOS_NS=higress-system

cd "$(dirname -- "$0")"
ROOT=$(dirname -- "$(pwd -P)")
COMPOSE_ROOT="$ROOT/compose"
cd - > /dev/null

source $COMPOSE_ROOT/.env

parseArgs() {
  resetEnv

  POSITIONAL_ARGS=()

  MODE="wizard"

  while [[ $# -gt 0 ]]; do
    case $1 in
      -r|--rerun)
        RERUN="Y"
        shift
        ;;
      -a|--auto-start)
        AUTO_START="Y"
        shift
        ;;
      -c|--config-url)
        EXTERNAL_NACOS_SERVER_URL="$2"
        MODE="params"
        shift
        shift
        ;;
      --use-builtin-nacos)
        USE_BUILTIN_NACOS="Y"
        MODE="params"
        shift
        ;;
      --nacos-ns)
        NACOS_NS="$2"
        MODE="params"
        shift
        shift
        ;;
      --nacos-username)
        NACOS_USERNAME="$2"
        MODE="params"
        shift
        shift
        ;;
      --nacos-password)
        NACOS_PASSWORD="$2"
        MODE="params"
        shift
        shift
        ;;
      --data-enc-key)
        NACOS_DATA_ENC_KEY="$2"
        MODE="params"
        shift
        shift
        ;;
      -p|--console-password)
        HIGRESS_CONSOLE_PASSWORD="$2"
        MODE="params"
        shift
        shift
        ;;
      -h|--help)
        outputUsage
        exit 0
        ;;
      -*|--*)
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
}

configure() {
  if [ "$MODE" == "params" ]; then
    configureByArgs
  else
    configureNacos
    configureConsole
  fi
  writeConfiguration
  runInitializer
  outputWelcomeMessage
}

resetEnv() {
  NACOS_SERVER_URL=""
  NACOS_NS=""
  NACOS_USERNAME=""
  NACOS_PASSWORD=""
  NACOS_DATA_ENC_KEY=""
  HIGRESS_CONSOLE_PASSWORD=""
}

configureByArgs() {
  if [ "$USE_BUILTIN_NACOS" == "Y" ] && [ -n "$EXTERNAL_NACOS_SERVER_URL" ]; then
    echo "Only one of the following flags shall be provided: --use-builtin-nacos, --config-url"
    exit -1
  fi

  if [ "$USE_BUILTIN_NACOS" == "Y" ] || [ -n "$EXTERNAL_NACOS_SERVER_URL" ]; then
    if [ "$USE_BUILTIN_NACOS" == "Y" ]; then
      NACOS_SERVER_URL="$BUILTIN_NACOS_SERVER_URL"
    else
      NACOS_SERVER_URL="$EXTERNAL_NACOS_SERVER_URL"
      if [[ $NACOS_SERVER_URL != "nacos://"* ]]; then
        echo "Only \"nacos://\" is supported in the Nacos URL at the moment."
        exit -1
      fi
      if [[ $NACOS_SERVER_URL == *"localhost"* ]] || [[ $NACOS_SERVER_URL == *"/127."* ]]; then
        echo "Higress will be running in a docker container. localhost or loopback addresses won't work. Please use a non-loopback host in the Nacos URL."
        exit -1
      fi
    fi
  else
    echo "One of the following flags shall be provided: --use-builtin-nacos, --config-url"
    exit -1
  fi

  if [ -n "$NACOS_USERNAME" ] || [ -n "$NACOS_PASSWORD" ]; then
    if [ "$USE_BUILTIN_NACOS" == "Y" ]; then
      echo "Built-in Nacos doesn't have auth enabled. Username and password settings will be ignored."
      NACOS_USERNAME=""
      NACOS_PASSWORD=""
    elif [ -z "$NACOS_USERNAME" ] || [ -z "$NACOS_PASSWORD" ]; then
      echo "Both Nacos username and password shall be provided."
      exit -1
    fi
  fi

  if [ "$USE_BUILTIN_NACOS" != "Y" ]; then
    KEY_LENGTH=${#NACOS_DATA_ENC_KEY}
    if [ $KEY_LENGTH == 0 ]; then
      echo "--data-enc-key is required when using external Nacos service."
      exit -1
    elif [ $KEY_LENGTH != 32 ]; then
      echo "Expecting 32 characters for --data-enc-key, but got ${KEY_LENGTH}."
      exit -1
    fi
  fi

  if [ "$USE_BUILTIN_NACOS" == "Y" ]; then
    echo "Starting built-in Nacos service..."
    cd "$COMPOSE_ROOT" && docker compose -p higress up -d nacos
  fi
}

configureNacos() {
  echo "==== Configure Nacos Service ===="
  while true
  do
    readNonEmpty "Use built-in Nacos service (Y/N): "
    enableNacos=$input
    if [ "$enableNacos" == "Y" ] || [ "$enableNacos" == "y" ]; then
      COMPOSE_PROFILES="nacos";
      NACOS_SERVER_URL="${BUILTIN_NACOS_SERVER_URL}"
      NACOS_USERNAME=""
      NACOS_PASSWORD=""

      echo "Starting built-in Nacos service..."
      cd "$COMPOSE_ROOT" && docker compose -p higress up -d nacos
      retVal=$?
      if [ $retVal -ne 0 ]; then
        echo ${1:-"  Starting built-in Nacos service fails with $retVal"}
        exit $retVal
      fi
      break;
    elif [ "$enableNacos" == "N" ] || [ "$enableNacos" == "n" ]; then
      COMPOSE_PROFILES=""
      configureStandaloneNacosServer
      break;
    else
      echo "Unknown input: $enableNacos"
    fi
  done
}

configureStandaloneNacosServer() {
  while true
  do
    readNonEmpty "Please input Nacos service URL (e.g. nacos://192.168.1.1:8848): "
    if [[ $input != "nacos://"* ]]; then
      echo "Only \"nacos://\" is supported at the moment."
      continue;
    fi
    if [[ $input == *"localhost"* ]] || [[ $input == *"/127."* ]]; then
      echo "Higress will be running in a docker container. localhost or loopback addresses won't work. Please use a non-loopback host in the URL."
      continue;
    fi
    NACOS_SERVER_URL=$input
    break
  done

  while true
  do
    readNonEmpty "Is authentication enabled in the Nacos service (Y/N): "
    enableNacosAuth=$input
    if [ "$enableNacosAuth" == "Y" ] || [ "$enableNacosAuth" == "y" ]; then
      readNonEmpty "Please provide the username to access Nacos: "
      NACOS_USERNAME=$input
      readNonEmptySecret "Please provide the password to access Nacos: "
      NACOS_PASSWORD=$input
      break;
    elif [ "$enableNacosAuth" == "N" ] || [ "$enableNacosAuth" == "n" ]; then
      NACOS_USERNAME=""
      NACOS_PASSWORD=""
      break;
    else
      echo "Unknown input: $enableNacosAuth"
    fi
  done

  readWithDefault "Please input Nacos namespace ID [${DEFAULT_NACOS_NS}]: " "$NACOS_NS"
  NACOS_NS=$input

  while true
  do
    readNonEmpty "Please input a 32-char long string for data encryption: "
    NACOS_DATA_ENC_KEY=$input
    KEY_LENGTH=${#NACOS_DATA_ENC_KEY}
    if [ $KEY_LENGTH != 32 ]; then
      echo "Expecting 32 characters, but got ${KEY_LENGTH}."
      continue;
    fi
    break;
  done
}

configureConsole() {
  echo "==== Configure Higress Console ===="
  echo "Username: admin"
  readNonEmptySecret "Please set password: "
  HIGRESS_CONSOLE_PASSWORD=$input
}

outputUsage() {
  echo 'Hello world!'
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
  echo "Higress is configured successfully."
  echo ""
  echo "Usage:"
  echo "  Start: $ROOT/bin/startup.sh"
  echo "  Stop: $ROOT/bin/stop.sh"
  echo "  View Component Statuses: $ROOT/bin/status.sh"
  echo "  View Logs: $ROOT/bin/logs.sh"
  echo "  Re-configure: $ROOT/bin/configure.sh -r"
  echo ""
  echo "Happy Higressing!"
}

writeConfiguration() {
  NACOS_SERVER_HTTP_URL=${NACOS_SERVER_URL/nacos:\/\//http://}
  NACOS_SERVER_HTTP_URL=${NACOS_SERVER_HTTP_URL%/}/nacos

  cat <<EOF > $COMPOSE_ROOT/.env
COMPOSE_PROFILES=${COMPOSE_PROFILES}
NACOS_SERVER_URL=${NACOS_SERVER_HTTP_URL}
NACOS_NS=${NACOS_NS:-${DEFAULT_NACOS_NS}}
NACOS_USERNAME=${NACOS_USERNAME}
NACOS_PASSWORD=${NACOS_PASSWORD}
NACOS_DATA_ENC_KEY=${NACOS_DATA_ENC_KEY}
NACOS_SERVER_TAG=${NACOS_SERVER_TAG}
HIGRESS_RUNNER_TAG=${HIGRESS_RUNNER_TAG}
HIGRESS_API_SERVER_TAG=${HIGRESS_API_SERVER_TAG}
HIGRESS_CONTROLLER_TAG=${HIGRESS_CONTROLLER_TAG}
HIGRESS_PILOT_TAG=${HIGRESS_PILOT_TAG}
HIGRESS_GATEWAY_TAG=${HIGRESS_GATEWAY_TAG}
HIGRESS_CONSOLE_TAG=${HIGRESS_CONSOLE_TAG}
HIGRESS_CONSOLE_PASSWORD=${HIGRESS_CONSOLE_PASSWORD}
EOF
}

runInitializer() {
  echo "==== Build Configurations ==== "

  cd "$COMPOSE_ROOT" && docker compose -p higress run --rm initializer
  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo "Higress configuration failed with $retVal."
    exit -1
  fi
}

readNonEmpty() {
  # $1 prompt
  while true
  do
    read -p "$1" input
    if [ -n "$input" ]; then
      break;
    fi
  done
}

readNonEmptySecret() {
  # $1 prompt
  while true
  do
    read -s -p "$1" input
    if [ -n "$input" ]; then
      echo ""
      break;
    fi
  done
}

readWithDefault() {
  # $1 prompt
  # $2 default
  read -p "$1" input
  if [ -z "$input" ]; then
    input="$2"
  fi
}

run() {
  bash $ROOT/bin/startup.sh
}

parseArgs "$@"
CONFIGURED_MARK="$COMPOSE_ROOT/.configured"
if [ -f "$CONFIGURED_MARK" ];  then
  if [ "$RERUN" == "Y" ]; then
    bash $ROOT/bin/reset.sh
  else
    echo "Higress is already configured. Please add \"-r\" if you want to re-run the configuration workflow."
    exit -1
  fi
fi
configure
touch "$CONFIGURED_MARK"
if [ "$AUTO_START" == "Y" ]; then
  echo ""
  echo ""
  run
fi
