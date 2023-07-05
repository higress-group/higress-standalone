#! /bin/bash

cd "$(dirname -- "$0")"
ROOT=$(dirname -- "$(pwd -P)")
COMPOSE_ROOT="$ROOT/compose"
cd - > /dev/null

source $COMPOSE_ROOT/.env

configure() {
  while true
  do
    readNonEmpty "Use built-in Nacos service (Y/N): "
    enableNacos=$input
    if [ "$enableNacos" == "Y" ] || [ "$enableNacos" == "y" ]; then
      COMPOSE_PROFILES="nacos";
      NACOS_SERVER_URL=http://nacos:8848/nacos/
      NACOS_USERNAME=""
      NACOS_PASSWORD=""
      cd "$COMPOSE_ROOT" && docker compose up -d nacos
      break;
    elif [ "$enableNacos" == "N" ] || [ "$enableNacos" == "n" ]; then
      COMPOSE_PROFILES=""
      configureStandaloneNacosServer
      break;
    else
      echo "Unknown input: $enableNacos"
    fi
  done

  cat <<EOF > $COMPOSE_ROOT/.env
COMPOSE_PROFILES=${COMPOSE_PROFILES}
NACOS_SERVER_URL=${NACOS_SERVER_URL}
NACOS_NS=${NACOS_NS}
NACOS_USERNAME=${NACOS_USERNAME}
NACOS_PASSWORD=${NACOS_PASSWORD}
NACOS_SERVER_TAG=${NACOS_SERVER_TAG}
HIGRESS_RUNNER_TAG=${HIGRESS_RUNNER_TAG}
HIGRESS_API_SERVER_TAG=${HIGRESS_API_SERVER_TAG}
HIGRESS_CONTROLLER_TAG=${HIGRESS_CONTROLLER_TAG}
HIGRESS_PILOT_TAG=${HIGRESS_PILOT_TAG}
HIGRESS_GATEWAY_TAG=${HIGRESS_GATEWAY_TAG}
HIGRESS_CONSOLE_TAG=${HIGRESS_CONSOLE_TAG}
EOF

  cd "$COMPOSE_ROOT" && docker compose run --rm initializer
  if [ $? -ne 0 ]; then
    exit -1
  fi
}

configureStandaloneNacosServer() {
  while true
  do
    readNonEmpty "Please input Nacos service URL (e.g. http://192.168.1.1:8848/nacos): "
    NACOS_SERVER_URL=$input
    if [[ $NACOS_SERVER_URL == *"localhost"* ]] || [[ $NACOS_SERVER_URL == *"/127."* ]]; then
      echo "Higress will be running in a docker container. localhost or loopback addresses won't work. Please use a non-loopback host in the URL."
      continue;
    fi
    # TODO: URL format validation
    break
  done

  NACOS_NS=${NACOS_NS-"higress-system"}
  readWithDefault "Please input Nacos namespace ID [${NACOS_NS}]: " "$NACOS_NS"
  NACOS_NS=$input

  while true
  do
    readNonEmpty "Is authentication enabled in the Nacos service (Y/N): "
    enableNacosAuth=$input
    if [ "$enableNacosAuth" == "Y" ] || [ "$enableNacosAuth" == "y" ]; then
      readNonEmpty "Please provide the username to access Nacos: "
      NACOS_USERNAME=$input
      readNonEmpty "Please provide the password to access Nacos: "
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
}

readNonEmpty() {
  # $1 prompt
  while true
  do
    read -p "$1" input
    if [ ! -z "$input" ]; then
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
  cd "$COMPOSE_ROOT" && COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose up
}

CONFIGURED_MARK="$COMPOSE_ROOT/.configured"
if [ ! -f "$CONFIGURED_MARK" ]; then
  configure
  touch "$CONFIGURED_MARK"
fi
run
