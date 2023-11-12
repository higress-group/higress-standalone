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
DEFAULT_NACOS_HTTP_PORT=8848
DEFAULT_GATEWAY_HTTP_PORT=80
DEFAULT_GATEWAY_HTTPS_PORT=443
DEFAULT_GATEWAY_METRICS_PORT=15020
DEFAULT_CONSOLE_PORT=8080

COMMAND_PREPARE="prepare"
COMMAND_INIT="init"
KNOWN_COMMANDS=($COMMAND_PREPARE, $COMMAND_INIT)

cd "$(dirname -- "$0")"
ROOT=$(dirname -- "$(pwd -P)")
COMPOSE_ROOT="$ROOT/compose"
cd - >/dev/null

source "$ROOT/bin/base.sh"

source "$COMPOSE_ROOT/.env"

CONFIGURED_MARK="$COMPOSE_ROOT/.configured"

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
    -r | --rerun)
      RERUN="Y"
      shift
      ;;
    -a | --auto-start)
      AUTO_START="Y"
      shift
      ;;
    -c)
      CONFIG_URL="$2"
      MODE="params"
      shift
      shift
      ;;
    --config-url=*)
      CONFIG_URL="${1#*=}"
      MODE="params"
      shift
      ;;
    --use-builtin-nacos)
      USE_BUILTIN_NACOS="Y"
      MODE="params"
      shift
      ;;
    --nacos-ns=*)
      NACOS_NS="${1#*=}"
      MODE="params"
      shift
      ;;
    --nacos-username=*)
      NACOS_USERNAME="${1#*=}"
      MODE="params"
      shift
      ;;
    --nacos-password=*)
      NACOS_PASSWORD="${1#*=}"
      MODE="params"
      shift
      ;;
    -k)
      NACOS_DATA_ENC_KEY="${2}"
      MODE="params"
      shift
      shift
      ;;
    --data-enc-key=*)
      NACOS_DATA_ENC_KEY="${1#*=}"
      MODE="params"
      shift
      ;;
    --s)
      CONFIG_STORAGE="$2"
      MODE="params"
      shift
      shift
      ;;
    --storage=*)
      CONFIG_STORAGE="${1#*=}"
      MODE="params"
      shift
      ;;
    --nacos-port=*)
      NACOS_HTTP_PORT="${1#*=}"
      MODE="params"
      shift
      ;;
    --gateway-http-port=*)
      GATEWAY_HTTP_PORT="${1#*=}"
      MODE="params"
      shift
      ;;
    --gateway-https-port=*)
      GATEWAY_HTTPS_PORT="${1#*=}"
      MODE="params"
      shift
      ;;
    --gateway-metrics-port=*)
      GATEWAY_METRICS_PORT="${1#*=}"
      MODE="params"
      shift
      ;;
    --console-port=*)
      CONSOLE_PORT="${1#*=}"
      MODE="params"
      shift
      ;;
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

  if [ -n "$COMMAND" ] && [[ ! ${KNOWN_COMMANDS[@]} =~ "$COMMAND" ]]; then
    echo "Unknown command: $COMMAND"
    exit 1
  fi

  if [ "$COMMAND" == "$COMMAND_PREPARE" ]; then
    if [ "$AUTO_START" == "Y" ]; then
      echo "Auto start flag is not available in \"$COMMAND_PREPARE\" command."
      exit 1
    fi
  elif [ "$COMMAND" == "$COMMAND_INIT" ]; then
    if [ "$MODE" == "params" ]; then
      echo "No configuration change is allowed in \"$COMMAND_INIT\" command."
      exit 1
    fi
  fi
}

configure() {
  if [ -z "$COMMAND" -o "$COMMAND" == "$COMMAND_PREPARE" ]; then
    if [ "$MODE" == "params" ]; then
      configureByArgs
    else
      configureStorage
      configureConsole
      configurePorts
    fi
    writeConfiguration
  fi

  if [ -z "$COMMAND" -o "$COMMAND" == "$COMMAND_INIT" ]; then
    runInitializer
    touch "$CONFIGURED_MARK"
    outputWelcomeMessage
  fi
}

resetEnv() {
  COMPOSE_PROFILES=""
  CONFIG_STORAGE=""
  FILE_ROOT_DIR=""
  NACOS_SERVER_URL=""
  NACOS_NS=""
  NACOS_USERNAME=""
  NACOS_PASSWORD=""
  NACOS_DATA_ENC_KEY=""

  NACOS_HTTP_PORT=$DEFAULT_NACOS_HTTP_PORT
  NACOS_GRPC_PORT=$(($DEFAULT_NACOS_HTTP_PORT + 1000))
  GATEWAY_HTTP_PORT=$DEFAULT_GATEWAY_HTTP_PORT
  GATEWAY_HTTPS_PORT=$DEFAULT_GATEWAY_HTTPS_PORT
  GATEWAY_METRICS_PORT=$DEFAULT_GATEWAY_METRICS_PORT
  CONSOLE_PORT=$DEFAULT_CONSOLE_PORT
}

configureByArgs() {
  if [ "$USE_BUILTIN_NACOS" == "Y" ] || [[ $CONFIG_URL == "nacos://"* ]]; then
    configureNacosByArgs
  elif [[ $CONFIG_URL == "file://"* ]]; then
    configureFileStorageByArgs
  else
    echo "Invalid config service URL: $CONFIG_URL"
    exit -1
  fi
  configureConsoleByArgs
  configurePortsByArgs
}

configureNacosByArgs() {
  CONFIG_STORAGE="nacos"

  if [ "$USE_BUILTIN_NACOS" == "Y" ] && [ -n "$CONFIG_URL" ]; then
    echo "Only one of the following flags shall be provided: --use-builtin-nacos, --config-url"
    exit -1
  fi

  if [ "$USE_BUILTIN_NACOS" == "Y" ] || [ -n "$CONFIG_URL" ]; then
    if [ "$USE_BUILTIN_NACOS" == "Y" ]; then
      if [ "$ARCH" != "amd64" ]; then
        echo "Sorry, built-in Nacos service doesn't support your platform. Please use a standalone Nacos service instead."
        exit -1
      fi
      COMPOSE_PROFILES="nacos"
      NACOS_SERVER_URL="$BUILTIN_NACOS_SERVER_URL"
    else
      COMPOSE_PROFILES=""
      NACOS_SERVER_URL="$CONFIG_URL"
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

  KEY_LENGTH=${#NACOS_DATA_ENC_KEY}
  if [ $KEY_LENGTH == 0 ]; then
    NACOS_DATA_ENC_KEY=$(cat /dev/urandom | head -n 10 | md5sum | head -c32)
  elif [ $KEY_LENGTH != 32 ] && [ "$USE_BUILTIN_NACOS" != "Y" ]; then
    echo "Expecting 32 characters for --data-enc-key, but got ${KEY_LENGTH}."
    exit -1
  fi
}

configureFileStorageByArgs() {
  CONFIG_STORAGE="file"

  FILE_ROOT_DIR="${CONFIG_URL#file://}"
  if [ "$OS" == "windows" ]; then
    # Fix path separators
    FILE_ROOT_DIR="${FILE_ROOT_DIR//\\//}"
    if [[ "$FILE_ROOT_DIR" == "."* ]] || [[ "$FILE_ROOT_DIR" == "~/"* ]]; then
      # A relatpath ive or user home based path. Do nothing.
      :
    elif [[ "$FILE_ROOT_DIR" != "/"* ]]; then
      echo 'Invalid file URL. Relative path must begin with a ".". Absolute path must begin with a "/" or "~/".'
      exit -1
    elif [[ "$FILE_ROOT_DIR" == *":"* ]]; then
      FILE_ROOT_DIR="${FILE_ROOT_DIR#/}"
    fi
  fi
  if [[ "$FILE_ROOT_DIR" == '~/'* ]]; then
    # A user home based path.
    FILE_ROOT_DIR="${HOME}${FILE_ROOT_DIR#\~}"
  fi
  mkdir -p "$FILE_ROOT_DIR" && cd "$_"
  if [ $? -ne 0 ]; then
    echo "Unable to create/access the config folder. Please fix it or choose another one."
    exit -1
  fi
  FILE_ROOT_DIR="$(pwd)"
  if [ "$OS" == "windows" ]; then
    FILE_ROOT_DIR="$(cygpath -w "$FILE_ROOT_DIR")"
  fi
  cd - &>/dev/null
}

configurePortsByArgs() {
  if [ "$CONFIG_STORAGE" == "nacos" ]; then
    if [ "$USE_BUILTIN_NACOS" == "Y" ]; then
      validatePort $NACOS_HTTP_PORT "Invalid --nacos-port value." 1
      NACOS_GRPC_PORT=$(($NACOS_HTTP_PORT + 1000))
      validatePort $NACOS_GRPC_PORT "--nacos-port value must be less than 64536." 1
    else
      NACOS_HTTP_PORT=$DEFAULT_NACOS_HTTP_PORT
      NACOS_GRPC_PORT=$(($DEFAULT_NACOS_HTTP_PORT + 1000))
    fi
  fi

  validatePort $GATEWAY_HTTP_PORT "Invalid --gateway-http-port value." 1
  validatePort $GATEWAY_HTTPS_PORT "Invalid --gateway-https-port value." 1
  validatePort $GATEWAY_METRICS_PORT "Invalid --gateway-metrics-port value." 1
  validatePort $CONSOLE_PORT "Invalid --console-port value." 1
}

configureConsoleByArgs() {
  :
}

configureStorage() {
  echo "==== Configure Config Storage ===="
  while true; do
    readNonEmpty "Please select a configuration storage (file/nacos): "
    CONFIG_STORAGE=$input
    if [ "$CONFIG_STORAGE" == "nacos" ]; then
      configureNacos
      break
    elif [ "$CONFIG_STORAGE" == "file" ]; then
      configureFileStorage
      break
    else
      echo "Unknown input: $CONFIG_STORAGE"
    fi
  done
}

configureNacos() {
  while true; do
    readNonEmpty "Use built-in Nacos service (Y/N): "
    enableBuiltInNacos=$input
    if [ "$enableBuiltInNacos" == "Y" ] || [ "$enableBuiltInNacos" == "y" ]; then
      if [ "$ARCH" != "amd64" ]; then
        echo "Sorry, built-in Nacos service doesn't support your platform."
        continue
      fi
      USE_BUILTIN_NACOS="Y"
      COMPOSE_PROFILES="nacos"
      NACOS_SERVER_URL="${BUILTIN_NACOS_SERVER_URL}"
      NACOS_USERNAME=""
      NACOS_PASSWORD=""
      break
    elif [ "$enableBuiltInNacos" == "N" ] || [ "$enableBuiltInNacos" == "n" ]; then
      COMPOSE_PROFILES=""
      configureStandaloneNacosServer
      break
    else
      echo "Unknown input: $enableBuiltInNacos"
    fi
  done
}

configureStandaloneNacosServer() {
  while true; do
    readNonEmpty "Please input Nacos service URL (e.g. nacos://192.168.1.1:8848): "
    if [[ $input != "nacos://"* ]]; then
      echo "Only \"nacos://\" is supported at the moment."
      continue
    fi
    if [[ $input == *"localhost"* ]] || [[ $input == *"/127."* ]]; then
      echo "Higress will be running in a docker container. localhost or loopback addresses won't work. Please use a non-loopback host in the URL."
      continue
    fi
    NACOS_SERVER_URL=$input
    break
  done

  while true; do
    readNonEmpty "Is authentication enabled in the Nacos service (Y/N): "
    enableNacosAuth=$input
    if [ "$enableNacosAuth" == "Y" ] || [ "$enableNacosAuth" == "y" ]; then
      readNonEmpty "Please provide the username to access Nacos: "
      NACOS_USERNAME=$input
      readNonEmptySecret "Please provide the password to access Nacos: "
      NACOS_PASSWORD=$input
      break
    elif [ "$enableNacosAuth" == "N" ] || [ "$enableNacosAuth" == "n" ]; then
      NACOS_USERNAME=""
      NACOS_PASSWORD=""
      break
    else
      echo "Unknown input: $enableNacosAuth"
    fi
  done

  readWithDefault "Please input Nacos namespace ID [${DEFAULT_NACOS_NS}]: " "$NACOS_NS"
  NACOS_NS=$input

  while true; do
    readWithDefault "Please input a 32-char long string for data encryption (Enter to generate a random one): " ""
    NACOS_DATA_ENC_KEY=$input
    KEY_LENGTH=${#NACOS_DATA_ENC_KEY}
    if [ $KEY_LENGTH == 0 ]; then
      NACOS_DATA_ENC_KEY=$(cat /dev/urandom | head -n 10 | md5sum | head -c32)
    elif [ $KEY_LENGTH != 32 ]; then
      echo "Expecting 32 characters, but got ${KEY_LENGTH}."
      continue
    fi
    break
  done
}

configureFileStorage() {
  while true; do
    readNonEmpty "Please input the root path of config folder: "
    FILE_ROOT_DIR="$input"
    if [ "$OS" == "windows" ]; then
      if [[ "$FILE_ROOT_DIR" == "."* ]]; then
        :
      elif [[ "$FILE_ROOT_DIR" == "/"* ]]; then
        :
      elif [[ "$FILE_ROOT_DIR" == *":"* ]]; then
        FILE_ROOT_DIR="${FILE_ROOT_DIR//\\//}"
      else
        FILE_ROOT_DIR="/${FILE_ROOT_DIR//\\//}"
      fi
    fi
    mkdir -p "$FILE_ROOT_DIR" && cd "$_"
    if [ $? -ne 0 ]; then
      echo "Unable to create/access the config folder. Please fix it or choose another one."
      continue
    fi
    FILE_ROOT_DIR="$(pwd)"
    if [ "$OS" == "windows" ]; then
      FILE_ROOT_DIR="$(cygpath -w "$FILE_ROOT_DIR")"
    fi
    cd - &>/dev/null
    break
  done
}

configureConsole() {
  # echo "==== Configure Higress Console ===="
  :
}

configurePorts() {
  echo "==== Configure Ports to be used by Higress ===="

  if [ "$USE_BUILTIN_NACOS" == "Y" ]; then
    while true; do
      readPortWithDefault "Please input the local HTTP port to access the built-in Nacos [${DEFAULT_NACOS_HTTP_PORT}]: " ${DEFAULT_NACOS_HTTP_PORT}
      NACOS_HTTP_PORT=$input
      NACOS_GRPC_PORT=$(($NACOS_HTTP_PORT + 1000))
      validatePort $NACOS_GRPC_PORT "The HTTP port of Nacos must be less than 64536." 0
      if [ $? -eq 0 ]; then
        break
      fi
    done
  fi
  readPortWithDefault "Please input the local HTTP port to access Higress Gateway [${DEFAULT_GATEWAY_HTTP_PORT}]: " ${DEFAULT_GATEWAY_HTTP_PORT}
  GATEWAY_HTTP_PORT=$input
  readPortWithDefault "Please input the local HTTPS port to access Higress Gateway [${DEFAULT_GATEWAY_HTTPS_PORT}]: " ${DEFAULT_GATEWAY_HTTPS_PORT}
  GATEWAY_HTTPS_PORT=$input
  readPortWithDefault "Please input the local metrics port to be listened by Higress Gateway [${DEFAULT_GATEWAY_METRICS_PORT}]: " ${DEFAULT_GATEWAY_METRICS_PORT}
  GATEWAY_METRICS_PORT=$input
  readPortWithDefault "Please input the local port to access Higress Console [${DEFAULT_CONSOLE_PORT}]: " ${DEFAULT_CONSOLE_PORT}
  CONSOLE_PORT=$input
}

outputUsage() {
  echo -n "Usage: $(basename -- "$0") [OPTIONS...]"
  echo '
 -a, --auto-start           start Higress after configuration
 -c, --config-url=URL       URL of the config storage
                            Use Nacos with format: nacos://192.168.0.1:8848
                            Use local files with format: file:///opt/higress/conf
     --use-builtin-nacos    use the built-in Nacos service instead of
                            an external one to store configurations
     --nacos-ns=NACOS-NAMESPACE
                            the ID of Nacos namespace to store configurations
                            default to "higress-system" if unspecified
     --nacos-username=NACOS-USERNAME
                            the username used to access Nacos
                            only needed if auth is enabled in Nacos
     --nacos-password=NACOS-PASSWORD
                            the password used to access Nacos
                            only needed if auth is enabled in Nacos
 -k, --data-enc-key=KEY     the key used to encrypt sensitive configurations
                            MUST contain 32 characters
                            A random key will be generated if unspecified
     --nacos-port=NACOS-PORT
                            the HTTP port used to access the built-in Nacos
                            default to 8848 if unspecified
     --gateway-http-port=GATEWAY-HTTP-PORT
                            the HTTP port to be listened by the gateway
                            default to 80 if unspecified
     --gateway-https-port=GATEWAY-HTTPS-PORT
                            the HTTPS port to be listened by the gateway
                            default to 443 if unspecified
     --gateway-metrics-port=GATEWAY-METRICS-PORT
                            the metrics port to be listened by the gateway
                            default to 15020 if unspecified
     --console-port=CONSOLE-PORT
                            the port used to visit Higress Console
                            default to 8080 if unspecified
 -r, --rerun                re-run the configuration workflow even if
                            Higress is already configured
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
  echo "Higress is configured successfully."
  echo ""
  if [ "$CONFIG_STORAGE" == "nacos" -a "$USE_BUILTIN_NACOS" != "Y" ]; then
    echo "Important Notes:"
    echo "  Sensitive configurations are encrypted when saving to Nacos."
    echo "  When configuring another server with the same Nacos configuration service, please make sure to add the following argument so all servers use the same encryption key:"
    echo "    --data-enc-key='${NACOS_DATA_ENC_KEY}'"
    echo ""
  fi
  echo "Usage:"
  echo "  Start: $ROOT/bin/startup.sh"
  echo "  Stop: $ROOT/bin/shutdown.sh"
  echo "  View Component Statuses: $ROOT/bin/status.sh"
  echo "  View Logs: $ROOT/bin/logs.sh"
  echo "  Re-configure: $ROOT/bin/configure.sh -r"
  echo ""
  echo "Happy Higressing!"
}

writeConfiguration() {
  if [ -z "$NACOS_SERVER_URL" ]; then
    NACOS_SERVER_HTTP_URL=""
  else
    NACOS_SERVER_HTTP_URL=${NACOS_SERVER_URL/nacos:\/\//http://}
    NACOS_SERVER_HTTP_URL=${NACOS_SERVER_HTTP_URL%/}/nacos
  fi

  cat <<EOF >$COMPOSE_ROOT/.env
COMPOSE_PROFILES='${COMPOSE_PROFILES}'
CONFIG_STORAGE='${CONFIG_STORAGE}'
FILE_ROOT_DIR='${FILE_ROOT_DIR}'
NACOS_SERVER_URL='${NACOS_SERVER_HTTP_URL}'
NACOS_NS='${NACOS_NS:-${DEFAULT_NACOS_NS}}'
NACOS_USERNAME='${NACOS_USERNAME}'
NACOS_PASSWORD='${NACOS_PASSWORD}'
NACOS_DATA_ENC_KEY='${NACOS_DATA_ENC_KEY}'
NACOS_SERVER_TAG='${NACOS_SERVER_TAG}'
HIGRESS_RUNNER_TAG='${HIGRESS_RUNNER_TAG}'
HIGRESS_API_SERVER_TAG='${HIGRESS_API_SERVER_TAG}'
HIGRESS_CONTROLLER_TAG='${HIGRESS_CONTROLLER_TAG}'
HIGRESS_PILOT_TAG='${HIGRESS_PILOT_TAG}'
HIGRESS_GATEWAY_TAG='${HIGRESS_GATEWAY_TAG}'
HIGRESS_CONSOLE_TAG='${HIGRESS_CONSOLE_TAG}'
NACOS_HTTP_PORT='${NACOS_HTTP_PORT}'
NACOS_GRPC_PORT='${NACOS_GRPC_PORT}'
GATEWAY_HTTP_PORT='${GATEWAY_HTTP_PORT}'
GATEWAY_HTTPS_PORT='${GATEWAY_HTTPS_PORT}'
GATEWAY_METRICS_PORT='${GATEWAY_METRICS_PORT}'
CONSOLE_PORT='${CONSOLE_PORT}'
EOF
}

runInitializer() {
  # Reload the latest env data from file.
  source "$COMPOSE_ROOT/.env"

  echo "==== Build Configurations ==== "

  if [ "$COMPOSE_PROFILES" == "nacos" ]; then
    echo "Starting built-in Nacos service..."
    cd "$COMPOSE_ROOT" && runDockerCompose -p higress up -d nacos
    retVal=$?
    if [ $retVal -ne 0 ]; then
      echo "Starting built-in Nacos service fails with $retVal"
      exit $retVal
    fi
  fi

  cd "$COMPOSE_ROOT" && runDockerCompose -p higress run -T --rm initializer
  local retVal=$?
  if [ $retVal -ne 0 ]; then
    echo "Higress configuration failed with $retVal."
    exit -1
  fi

  if [ "$COMPOSE_PROFILES" == "nacos" ] && [ "${AUTO_START}" != "Y" ]; then
    echo "Stopping built-in Nacos service..."
    cd "$COMPOSE_ROOT" && runDockerCompose -p higress down --remove-orphans
    local retVal=$?
    if [ $retVal -ne 0 ]; then
      echo "Stopping built-in Nacos service fails with $retVal"
    fi
  fi
}

readNonEmpty() {
  # $1 prompt
  while true; do
    read -r -p "$1" input
    if [ -n "$input" ]; then
      break
    fi
  done
}

readNonEmptySecret() {
  # $1 prompt
  while true; do
    read -r -s -p "$1" input
    if [ -n "$input" ]; then
      echo ""
      break
    fi
  done
}

readWithDefault() {
  # $1 prompt
  # $2 default
  read -r -p "$1" input
  if [ -z "$input" ]; then
    input="$2"
  fi
}

readPortWithDefault() {
  # $1 prompt
  # $2 default
  for (( ; ; )); do
    read -r -p "$1" input
    if [ -z "$input" ]; then
      input="$2"
      break
    fi
    validatePort "$input" "Invalid port number." 0
    if [ $? -eq 0 ]; then
      break
    fi
  done
}

validatePort() {
  # $1 port
  # $2 error message
  # $3 exit when error if set to 1
  if [[ $1 =~ ^[0-9]+$ ]] && [ $1 -gt 0 ] && [ $1 -lt 65536 ]; then
    return 0
  fi
  echo "$2"
  if [ $3 -eq 1 ]; then
    exit -1
  else
    return -1
  fi
}

run() {
  echo "Starting Higress..."
  echo ""
  bash $ROOT/bin/startup.sh
}

initArch
initOS
parseArgs "$@"
if [ -f "$CONFIGURED_MARK" ]; then
  if [ "$RERUN" == "Y" ]; then
    bash $ROOT/bin/reset.sh
  else
    echo "Higress is already configured. Please add \"-r\" if you want to re-run the configuration workflow."
    exit -1
  fi
fi
configure
if [ "${AUTO_START}" == "Y" ]; then
  echo ""
  run
fi
