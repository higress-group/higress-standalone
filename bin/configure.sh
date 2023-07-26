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
      -c)
        EXTERNAL_NACOS_SERVER_URL="$2"
        MODE="params"
        shift
        shift
        ;;
      --config-url=*)
        EXTERNAL_NACOS_SERVER_URL="${1#*=}"
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
      -p)
        HIGRESS_CONSOLE_PASSWORD="$2"
        MODE="params"
        shift
        shift
        ;;
      --console-password=*)
        HIGRESS_CONSOLE_PASSWORD="${1#*=}"
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
    configurePorts
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

  NACOS_HTTP_PORT=$DEFAULT_NACOS_HTTP_PORT
  NACOS_GRPC_PORT=$(($DEFAULT_NACOS_HTTP_PORT + 1000))
  GATEWAY_HTTP_PORT=$DEFAULT_GATEWAY_HTTP_PORT
  GATEWAY_HTTPS_PORT=$DEFAULT_GATEWAY_HTTPS_PORT
  GATEWAY_METRICS_PORT=$DEFAULT_GATEWAY_METRICS_PORT
  CONSOLE_PORT=$DEFAULT_CONSOLE_PORT
}

configureByArgs() {
  if [ "$USE_BUILTIN_NACOS" == "Y" ] && [ -n "$EXTERNAL_NACOS_SERVER_URL" ]; then
    echo "Only one of the following flags shall be provided: --use-builtin-nacos, --config-url"
    exit -1
  fi

  if [ "$USE_BUILTIN_NACOS" == "Y" ] || [ -n "$EXTERNAL_NACOS_SERVER_URL" ]; then
    if [ "$USE_BUILTIN_NACOS" == "Y" ]; then
      COMPOSE_PROFILES="nacos";
      NACOS_SERVER_URL="$BUILTIN_NACOS_SERVER_URL"
    else
      COMPOSE_PROFILES=""
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

  KEY_LENGTH=${#NACOS_DATA_ENC_KEY}
  if [ $KEY_LENGTH == 0 ]; then
    NACOS_DATA_ENC_KEY=$(cat /dev/urandom | head -n 10 | md5sum |head -c32)
  elif [ $KEY_LENGTH != 32 ] && [ "$USE_BUILTIN_NACOS" != "Y" ]; then
    echo "Expecting 32 characters for --data-enc-key, but got ${KEY_LENGTH}."
    exit -1
  fi

  if [ -z "$HIGRESS_CONSOLE_PASSWORD" ]; then
      HIGRESS_CONSOLE_PASSWORD=$(cat /dev/urandom | head -n 10 | md5sum |head -c32)
  fi

  if [ "$USE_BUILTIN_NACOS" == "Y" ]; then
    validatePort $NACOS_HTTP_PORT "Invalid --nacos-port value." 1
    NACOS_GRPC_PORT=$(($NACOS_HTTP_PORT + 1000))
    validatePort $NACOS_GRPC_PORT "--nacos-port value must be less than 64536." 1
  else
    NACOS_HTTP_PORT=$DEFAULT_NACOS_HTTP_PORT
    NACOS_GRPC_PORT=$(($DEFAULT_NACOS_HTTP_PORT + 1000))
  fi
  validatePort $GATEWAY_HTTP_PORT "Invalid --gateway-http-port value." 1
  validatePort $GATEWAY_HTTPS_PORT "Invalid --gateway-https-port value." 1
  validatePort $GATEWAY_METRICS_PORT "Invalid --gateway-metrics-port value." 1
  validatePort $CONSOLE_PORT "Invalid --console-port value." 1
}

configureNacos() {
  echo "==== Configure Nacos Service ===="
  while true
  do
    readNonEmpty "Use built-in Nacos service (Y/N): "
    enableNacos=$input
    if [ "$enableNacos" == "Y" ] || [ "$enableNacos" == "y" ]; then
      USE_BUILTIN_NACOS="Y"
      COMPOSE_PROFILES="nacos";
      NACOS_SERVER_URL="${BUILTIN_NACOS_SERVER_URL}"
      NACOS_USERNAME=""
      NACOS_PASSWORD=""
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
    readWithDefault "Please input a 32-char long string for data encryption (Enter to generate a random one): " ""
    NACOS_DATA_ENC_KEY=$input
    KEY_LENGTH=${#NACOS_DATA_ENC_KEY}
    if [ $KEY_LENGTH == 0 ]; then
      NACOS_DATA_ENC_KEY=$(cat /dev/urandom | head -n 10 | md5sum |head -c32)
    elif [ $KEY_LENGTH != 32 ]; then
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

configurePorts() {
  echo "==== Configure Ports to be used by Higress ===="

  if [ "$USE_BUILTIN_NACOS" == "Y" ]; then
    while true
    do
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
 -c, --config-url=URL       URL of the Nacos service
                            format: nacos://192.168.0.1:8848
     --use-builtin-nacos    use the built-in Nacos service instead of
                            an external one
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
 -p, --console-password=CONSOLE-PASSWORD
                            the password to be used to visit Higress Console
                            default to random string if unspecified
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
                            default to 15012 if unspecified
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
  if [ "$USE_BUILTIN_NACOS" != "Y" ]; then
    echo "Important Notes:"
    echo "  Sensitive configurations are encrypted when saving to Nacos."
    echo "  When configuring another server with the same Nacos configuration service, please make sure to add the following argument so all servers use the same encryption key:"
    echo "    --data-enc-key='${NACOS_DATA_ENC_KEY}'"
  echo ""
  fi
  echo "Usage:"
  echo "  Start: $ROOT/bin/startup.sh"
  echo "  Stop: $ROOT/bin/stop.sh"
  echo "  View Component Statuses: $ROOT/bin/status.sh"
  echo "  View Logs: $ROOT/bin/logs.sh"
  echo "  Re-configure: $ROOT/bin/configure.sh -r"
  echo ""
  echo "Note:"
  echo " Higress Console Username: admin"
  echo " Higress Console Password: ${HIGRESS_CONSOLE_PASSWORD}"
  echo ""
  echo "Happy Higressing!"
}

writeConfiguration() {
  NACOS_SERVER_HTTP_URL=${NACOS_SERVER_URL/nacos:\/\//http://}
  NACOS_SERVER_HTTP_URL=${NACOS_SERVER_HTTP_URL%/}/nacos

  cat <<EOF > $COMPOSE_ROOT/.env
COMPOSE_PROFILES='${COMPOSE_PROFILES}'
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
HIGRESS_CONSOLE_PASSWORD='${HIGRESS_CONSOLE_PASSWORD}'
NACOS_HTTP_PORT='${NACOS_HTTP_PORT}'
NACOS_GRPC_PORT='${NACOS_GRPC_PORT}'
GATEWAY_HTTP_PORT='${GATEWAY_HTTP_PORT}'
GATEWAY_HTTPS_PORT='${GATEWAY_HTTPS_PORT}'
GATEWAY_METRICS_PORT='${GATEWAY_METRICS_PORT}'
CONSOLE_PORT='${CONSOLE_PORT}'
EOF
}

runInitializer() {
  echo "==== Build Configurations ==== "

  if [ "$USE_BUILTIN_NACOS" == "Y" ]; then
    echo "Starting built-in Nacos service..."
    cd "$COMPOSE_ROOT" && docker-compose -p higress up -d nacos
    retVal=$?
    if [ $retVal -ne 0 ]; then
      echo "Starting built-in Nacos service fails with $retVal"
      exit $retVal
    fi
  fi

  cd "$COMPOSE_ROOT" && docker-compose -p higress run -T --rm initializer
  local retVal=$?
  if [ $retVal -ne 0 ]; then
    echo "Higress configuration failed with $retVal."
    exit -1
  fi

  if [ "$USE_BUILTIN_NACOS" == "Y" ] && [ "${AUTO_START}" != "Y" ]; then
    echo "Stopping built-in Nacos service..."
    cd "$COMPOSE_ROOT" && docker-compose -p higress down --remove-orphans
    local retVal=$?
    if [ $retVal -ne 0 ]; then
      echo "Stopping built-in Nacos service fails with $retVal"
    fi
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

readPortWithDefault() {
  # $1 prompt
  # $2 default
  for (( ; ; ))
  do
    read -p "$1" input
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
if [ "${AUTO_START}" == "Y" ]; then
  echo ""
  run
fi
