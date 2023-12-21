#! /bin/bash

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

VOLUMES_ROOT="/mnt/volumes"
RSA_KEY_LENGTH=4096

NACOS_SERVER_URL=${NACOS_SERVER_URL%/}
NACOS_ACCESS_TOKEN=""
FILE_ROOT_DIR="/opt/data"

now() {
  echo "$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
}

checkExitCode() {
  # $1 message
  retVal=$?
  if [ $retVal -ne 0 ]; then
    echo ${1:-"  Command fails with $retVal"}
    exit $retVal
  fi
}

checkConfigExists() {
  # $1 namespace
  # $2 configType: plural
  # $3 configName
  case $CONFIG_STORAGE in
    nacos)
      checkNacosConfigExists "$@"
      return $?
      ;;
    file)
      checkFileConfigExists "$@"
      return $?
      ;;
    *)
      printf "  Unknown storage type: %s\n" "$CONFIG_STORAGE"
      exit -1
      ;;
  esac
}

checkNacosConfigExists() {
  # $1 namespace
  # $2 configType: plural
  # $3 configName
  local group="$1"
  local dataId="$2.$3"
  statusCode=$(curl -s -o /dev/null -w "%{http_code}" "${NACOS_SERVER_URL}/v1/cs/configs?accessToken=${NACOS_ACCESS_TOKEN}&tenant=${NACOS_NS}&dataId=${dataId}&group=${group}")
  if [ $statusCode -eq 200 ]; then
    return 0
  elif [ $statusCode -eq 404 ]; then
    return -1
  else
    echo "  Checking config ${group}/${dataId} in namespace ${NACOS_NS} failed with ${statusCode}"
    exit -1
  fi
}

checkFileConfigExists() {
  # $1 namespace: ignored. only for alignment
  # $2 configType: plural
  # $3 configName
  local configFile="${FILE_ROOT_DIR}/$2/$3.yaml"
  if [ -f "$configFile" ]; then
    return 0
  else
    return 1
  fi
}

getConfig() {
  # $1 namespace
  # $2 configType: plural
  # $3 configName
  case $CONFIG_STORAGE in
    nacos)
      getNacosConfig "$@"
      ;;
    file)
      getFileConfig "$@"
      ;;
    *)
      printf "  Unknown storage type: %s\n" "$CONFIG_STORAGE"
      exit -1
      ;;
  esac
}

getNacosConfig() {
  # $1 namespace
  # $2 configType: plural
  # $3 configName
  local group="$1"
  local dataId="$2.$3"

  config=""
  tmpFile=$(mktemp /tmp/higress-precheck-nacos.XXXXXXXXX.cfg)
  statusCode=$(curl -s -o "$tmpFile" -w "%{http_code}" "${NACOS_SERVER_URL}/v1/cs/configs?accessToken=${NACOS_ACCESS_TOKEN}&tenant=${NACOS_NS}&dataId=${dataId}&group=${group}")
  if [ $statusCode -eq 200 ]; then
    config=$(cat "$tmpFile")
    rm "$tmpFile"
    return 0
  elif [ $statusCode -eq 404 ]; then
    config = ""
    return -1
  else
    echo ${1:-"  Getting config ${group}/${dataId} in namespace ${NACOS_NS} failed with $retVal"}
    exit -1
  fi
}

getFileConfig() {
  # $1 namespace: ignored. only for alignment
  # $2 configType: plural
  # $3 configName
  local configFile="${FILE_ROOT_DIR}/$2/$3.yaml"
  if [ -f "$configFile" ]; then
    config=$(cat "$configFile")
    return 0
  else
    config = ""
    return -1
  fi
}

checkStorage() {
  CONFIG_STORAGE=${CONFIG_STORAGE:-nacos}

  case $CONFIG_STORAGE in
    nacos)
      checkNacos
      ;;
    file)
      checkConfigDir
      ;;
    *)
      printf "Unsupported storage type: %s\n" "$CONFIG_STORAGE"
      ;;
  esac
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

checkConfigDir() {
  echo "Initializing Config Directory..."
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

  mkdir -p $VOLUMES_ROOT/pilot/config && cd "$_"
  getConfig "higress-system" "configmaps" "higress-config"
  checkExitCode "  The ConfigMap resource of 'higress-config' doesn't exist."
  fileNames=$(yq '.data | keys | .[]' <<< "$config")
  if [ -z "$fileNames" ]; then
    echo "  Missing required files in higress-config ConfigMap."
    exit -1
  fi
  IFS=$'\n'
  for fileName in $fileNames
  do
    if [ -z "$fileName" ]; then
      continue
    fi
    echo "$config" | yq ".data.$fileName" > "./$fileName"
  done
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

  checkConfigExists "higress-system" "configmaps" "higress-console"
  if [ $? -ne 0 ]; then
    echo "  The ConfigMap resource of Higress Console doesn't exist."
    exit -1
  fi
  checkConfigExists "higress-system" "secrets" "higress-console"
  if [ $? -ne 0 ]; then
    echo "  The Secret resource of Higress Console doesn't exist."
    exit -1
  fi
}

checkStorage
checkApiServer
checkPilot
checkGateway
checkConsole
