#! /bin/bash

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

VOLUMES_ROOT="/mnt/volumes"
RSA_KEY_LENGTH=4096

NACOS_SERVER_URL=${NACOS_SERVER_URL%/}
NACOS_ACCESS_TOKEN=""

now() {
  echo "$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
}

base64_urlencode() {
  openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; 
}

check_exit_code() {
  # $1 message
  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo ${1:-"  Command fails with $retVal"}
    exit $retVal
  fi
}

check_nacos_config_exists() {
  # $1 group
  # $2 dataId
  statusCode=$(curl -s -o /dev/null -w "%{http_code}" "${NACOS_SERVER_URL}/v1/cs/configs?accessToken=${NACOS_ACCESS_TOKEN}&tenant=${NACOS_NS}&dataId=$2&group=$1")
  if [ $statusCode -eq 200 ]; then
    return 0
  elif [ $statusCode -eq 404 ]; then
    return -1
  else
    echo ${1:-"  Checking config $1/$2 in namespace ${NACOS_NS} failed with $retVal"}
    exit -1
  fi
}

checkNacos() {
  echo "Checking Nacos server..."

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

  if [ -n "$NACOS_USERNAME" ] && [ -n "$NACOS_PASSWORD" ]; then
    curl -sv "${NACOS_SERVER_URL}/v1/auth/login" -X POST --data-urlencode "username=${NACOS_USERNAME}" --data-urlencode "password=${NACOS_PASSWORD}" 
    NACOS_ACCESS_TOKEN="$(curl -s "${NACOS_SERVER_URL}/v1/auth/login" -X POST --data-urlencode "username=${NACOS_USERNAME}" --data-urlencode "password=${NACOS_PASSWORD}" | jq -rM '.accessToken')";
    if [ -z "$NACOS_ACCESS_TOKEN" ]; then
      echo "Unable to retrieve access token from Nacos. Possible causes are:"
      echo "  1. Incorrect username or password."
      echo "  2. The target Nacos service doesn't have authentication enabled."
    fi
  fi

  nacosNamespaces=$(curl -s "${NACOS_SERVER_URL}/v1/console/namespaces?accessToken=${NACOS_ACCESS_TOKEN}")
  if [[ "$nacosNamespaces" != *"\"namespace\":\"${NACOS_NS}\""* ]]; then
    echo "  Unable to find namespace ${NACOS_NS} in Nacos."
    exit -1
  fi
}

checkApiServer() {
  echo "Checking API server configurations..."

  if [ ! -d "$VOLUMES_ROOT/api/" ]; then
    echo "  The volume of api is missing."
    exit -1 
  fi
  cd "$VOLUMES_ROOT/api"

  if [ ! -f ca.key ] || [ ! -f ca.crt ]; then
    echo "  CA certificate files of API server are missing."
    exit -1 
  fi
  if [ ! -f server.key ] || [ ! -f server.crt ]; then
    echo "  Server certificate files of API server are missing."
    exit -1 
  fi
  if [ ! -f nacos.key ]; then
    echo "  The data encryption key file is missing."
    exit -1 
  fi
  if [ ! -f client.key ] || [ ! -f client.crt ]; then
    echo "  Client certificate files of API server are missing."
    exit -1 
  fi

  if [ ! -f $VOLUMES_ROOT/kube/config ]; then
    echo "  The kubeconfig file to access API server is missing."
    exit -1 
  fi
}

checkPilot() {
  echo "Checking pilot configurations..."

  if [ ! -d "$VOLUMES_ROOT/pilot/" ]; then
    echo "  The volume of pilot is missing."
    exit -1 
  fi

  if [ ! -d "$VOLUMES_ROOT/pilot/cacerts/" ]; then
    echo "  The cacerts folder of pilot is missing."
    exit -1 
  fi
  cd $VOLUMES_ROOT/pilot/cacerts

  if [ ! -f root-key.pem ] || [ ! -f root-cert.pem ]; then
    echo "  The root CA certificate files of pilot are missing."
    exit -1 
  fi

  if [ ! -f ca-key.pem ] || [ ! -f ca-cert.pem ] || [ ! -f cert-chain.pem ]; then
    echo "  The CA certificate files of pilot are missing."
    exit -1 
  fi

  if [ ! -f gateway-key.pem ] || [ ! -f gateway-cert.pem ]; then
    echo "  The gateway certificate files of pilot are missing."
    exit -1 
  fi

  if [ ! -d "$VOLUMES_ROOT/pilot/config/" ]; then
    echo "  The config folder of pilot is missing."
    exit -1 
  fi
  cd $VOLUMES_ROOT/pilot/config/
  if [ ! -f "./mesh" ] && [ ! -f "./meshNetworks" ]; then
    echo "  One or some of the mesh configuration files of pilot are missing."
    exit -1 
  fi
}

checkGateway() {
  echo "Checking gateway configurations..."

  if [ ! -d "$VOLUMES_ROOT/gateway/certs/" ]; then
    echo "  The cacerts folder of gateway is missing."
    exit -1 
  fi
  cd $VOLUMES_ROOT/gateway/certs/
  if [ ! -f "./root-cert.pem" ] && [ ! -f "./cert-chain.pem" ] && [ ! -f "./key.pem" ]; then
    echo "  One or some of the certificate files of gateway is missing."
    exit -1 
  fi

  if [ ! -f "$VOLUMES_ROOT/gateway/podinfo/labels" ]; then
    echo "  The labels file of gateway are missing."
    exit -1 
  fi
}

checkConsole() {
  echo "Checking console configurations..."

  check_nacos_config_exists "higress-system" "configmaps.higress-console"
  if [ ! $?  ]; then
    echo "  The ConfigMap resource of Higress Console isn't found in Nacos."
    exit -1
  fi
  check_nacos_config_exists "higress-system" "secrets.higress-console"
  if [ ! $? ]; then
    echo "  The Secret resource of Higress Console isn't found in Nacos."
    exit -1
  fi
}

checkNacos
checkApiServer
checkPilot
checkGateway
checkConsole
