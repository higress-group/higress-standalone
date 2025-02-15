#! /bin/bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VOLUMES_ROOT="/mnt/volumes"
RSA_KEY_LENGTH=4096

NACOS_SERVER_URL=${NACOS_SERVER_URL%/}
NACOS_ACCESS_TOKEN=""
FILE_ROOT_DIR="/opt/data"

now() {
  echo "$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
}

base64UrlEncode() {
  openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; 
}

checkExitCode() {
  # $1 message
  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo ${1:-"  Command fails with $retVal"}
    exit $retVal
  fi
}

initializeConfigStorage() {
  CONFIG_STORAGE=${CONFIG_STORAGE:-nacos}

  case $CONFIG_STORAGE in
  nacos)
    initializeNacos
    ;;
  file)
    initializeConfigDir
      ;;
    *)
      printf "Unsupported storage type: %s\n" "$CONFIG_STORAGE"
      ;;
  esac
}

initializeNacos() {
  nacosReady=false

  maxWaitTime=180
  for (( i = 0; i < $maxWaitTime; i++ ))
  do
    statusCode=$(curl -s -o /dev/null -w "%{http_code}" "${NACOS_SERVER_URL}/")
    if [ "$statusCode" -eq "200" ]; then
      nacosReady=true
      echo "Nacos is ready."
      break
    fi
    echo "Waiting for Nacos to get ready..."
    sleep 1
  done

  if [ "${nacosReady}" != "true" ]; then
    echo "Nacos server doesn't get ready within ${maxWaitTime} seconds. Initialization failed."
    exit -1 
  fi

  echo "Initializing Nacos server..."

  if [ -n "$NACOS_USERNAME" ] && [ -n "$NACOS_PASSWORD" ]; then
    NACOS_ACCESS_TOKEN="$(curl -s "${NACOS_SERVER_URL}/v1/auth/login" -X POST --data-urlencode "username=${NACOS_USERNAME}" --data-urlencode "password=${NACOS_PASSWORD}" | jq -rM '.accessToken')";
    if [ -z "$NACOS_ACCESS_TOKEN" ]; then
      echo "Unable to retrieve access token from Nacos. Possible causes are:"
      echo "  1. Incorrect username or password."
      echo "  2. The target Nacos service doesn't have authentication enabled."
    fi
  fi

  if grep -q "\"namespace\":\"${NACOS_NS}\"" <<<"$(curl -s "${NACOS_SERVER_URL}/v1/console/namespaces?accessToken=${NACOS_ACCESS_TOKEN}")"; then
    echo "  Namespace ${NACOS_NS} already exists in Nacos."

    if [ "$NACOS_USE_RANDOM_DATA_ENC_KEY" != "Y" ]; then
      echo "  Fixed data encryption key is used. Skip config overwriting check."
    else
      echo "  Checking existed configs in namespace ${NACOS_NS}..."
      statusCode="$(curl -s -o /dev/null -w "%{http_code}" "${NACOS_SERVER_URL}/v2/cs/config?accessToken=${NACOS_ACCESS_TOKEN}&namespaceId=${NACOS_NS}&dataId=secrets.__names__&group=DEFAULT_GROUP")"
      if [ $statusCode -eq 200 ]; then
        echo "  ERROR: Higress configs are found in nacos namespace ${NACOS_NS}."
        echo
        echo "  Using a random data encyption key in a configured nacos namespace is incorrect, and will cause Higress unable to start."
        echo "  You can:"
        echo "  1. Remove all the configurations in nacos namespace ${NACOS_NS} and try again."
        echo "  2. Install Higress to another nacos namespace."
        echo "  3. Specify the same data encryption key generated/used in the previous installation."
        exit -1
      elif [ $statusCode -eq 404 ]; then
        echo "  No Higress config is found in nacos namespace ${NACOS_NS}."
      else
        echo "  Checking existed configs in nacos namespace ${NACOS_NS} failed with $statusCode."
        exit -1
      fi
    fi

    return 0
  fi

  echo "  Creating namespace ${NACOS_NS}..."
  statusCode="$(curl -s -o /dev/null -w "%{http_code}" "${NACOS_SERVER_URL}/v1/console/namespaces?accessToken=${NACOS_ACCESS_TOKEN}" --data-urlencode "customNamespaceId=${NACOS_NS}" --data-urlencode "namespaceName=${NACOS_NS}")"
  if [ $statusCode -ne 200 ]; then
    echo "  Creating namespace ${NACOS_NS} in nacos failed with $statusCode."
    exit -1
  fi
  return 0
}

initializeConfigDir() {
  echo "Initializing Config Directory..."

  if [ -z "$FILE_ROOT_DIR" ]; then
    echo "  Config directory isn't specified."
    exit -1
  fi

  mkdir -p "$FILE_ROOT_DIR"
  checkExitCode "  Creating config directory [$FILE_ROOT_DIR] fails with $?"
}

initializeApiServer() {
  echo "Initializing API server configurations..."

  mkdir -p "$VOLUMES_ROOT/api" && cd "$_"
  checkExitCode "Creating volume for API server fails with $?"

  if [ ! -f nacos.key ]; then
    echo "  Generating data encryption key..."
    if [ -z "$NACOS_DATA_ENC_KEY" ]; then
      cat /dev/urandom | tr -dc '[:graph:]' | head -c 32 > nacos.key
    else
      echo -n "$NACOS_DATA_ENC_KEY" > nacos.key
    fi
  else
    echo "  Data encryption key already exists.";
  fi
}

initializeController() {
  echo "Initializing controller configurations..."

  mkdir -p $VOLUMES_ROOT/controller && cd "$_"

  if [ "$CONFIG_STORAGE" == "nacos" ]; then
    mkdir -p ./log/nacos
    chmod a+w ./log/nacos
  fi
}


initializeConfigStorage
initializeApiServer
initializeController
