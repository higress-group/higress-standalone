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
  openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
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

  nacosApiVersion=1

  maxWaitTime=180
  local tmpFile=$(mktemp /tmp/higress-init.XXXXXXXXX.cfg)
  for ((i = 0; i < $maxWaitTime; i++)); do
    # We always check the readiness with v1 API. 
    # If it's actually v3, the response will depend on the value of "nacos.core.api.compatibility.console.enabled" config:
    # - If true, it will return a 404 error with "No endpoint GET /nacos/v1/console/health/readiness" in the content.
    # - If false, it will return a 410 error.
    local healthCheckUrl="${NACOS_SERVER_URL}/v1/console/health/readiness"
    statusCode=$(curl -s -o "${tmpFile}" -w "%{http_code}" "$healthCheckUrl")
    if [ "$statusCode" -eq "410" -o "$statusCode" -eq "404" -a -n "$(cat "$tmpFile" | grep "No endpoint")" ]; then
      # Just double check here with a v3 API to confirm.
      local v3HealthCheckurl="${NACOS_SERVER_URL}/v3/admin/core/state"
      v3StatusCode=$(curl -s -o /dev/null -w "%{http_code}" "$v3HealthCheckurl")
      if [ "$v3StatusCode" -ne "200" ]; then
        echo "Unexpected Nacos health check result: 
- Got ${statusCode} from ${healthCheckUrl}
- Got ${v3StatusCode} from ${v3HealthCheckurl}"
        continue
      fi
      nacosReady=true
      nacosApiVersion=3
      break
    elif [ "$statusCode" -eq "200" ]; then
      nacosReady=true
      break
    fi
    if [ $(($i % 5)) == 0 -a "$COMPOSE_PROFILES" != "nacos" ]; then
      # No status echo for built-in nacos
      echo "$healthCheckUrl returns $statusCode"
    fi
    echo "Waiting for Nacos to get ready..."
    sleep 1
  done
  rm "${tmpFile}"

  if [ "${nacosReady}" != "true" ]; then
    echo "Nacos server doesn't get ready within ${maxWaitTime} seconds. Initialization failed."
    exit -1
  fi

  echo "Nacos is ready."

  echo "Initializing Nacos server..."

  if [ -n "$NACOS_USERNAME" ] && [ -n "$NACOS_PASSWORD" ]; then
    NACOS_ACCESS_TOKEN="$(curl -s "${NACOS_SERVER_URL}/v1/auth/login" -X POST --data-urlencode "username=${NACOS_USERNAME}" --data-urlencode "password=${NACOS_PASSWORD}" | jq -rM '.accessToken')"
    # nacos-go-sdk is still using the API above for login. There is no need to support the new V3 API here.
    # if [ "$nacosApiVersion" == "1" ]; then
    #   NACOS_ACCESS_TOKEN="$(curl -s "${NACOS_SERVER_URL}/v1/auth/login" -X POST --data-urlencode "username=${NACOS_USERNAME}" --data-urlencode "password=${NACOS_PASSWORD}" | jq -rM '.accessToken')"
    # elif [ "$nacosApiVersion" == "3" ]; then
    #   NACOS_ACCESS_TOKEN="$(curl -s "${NACOS_SERVER_URL}/v3/auth/user/login" -X POST --data-urlencode "username=${NACOS_USERNAME}" --data-urlencode "password=${NACOS_PASSWORD}" | jq -rM '.accessToken')"
    # else
    #   echo "Unsupported Nacos API version: v$nacosApiVersion"
    #   exit -1
    # fi
    if [ -z "$NACOS_ACCESS_TOKEN" ]; then
      echo "Unable to retrieve access token from Nacos. Possible causes are:"
      echo "  1. Incorrect username or password."
      echo "  2. The target Nacos service doesn't have authentication enabled."
      if [ "$nacosApiVersion" == "3" ]; then
        echo "  3. When using Nacos 3.x, please make sure the following property is set to true:
    nacos.core.api.compatibility.client.enabled=true"
      fi
    fi
  fi

  if [ "$nacosApiVersion" == "3" ]; then
    # TODO: Remove extra compatibility check after nacos-go-sdk fully supports Nacos 3.x
    checkNacos3ApiCompatibility
  fi

  # Only $nacosApiVersion 1 and 3 are supported below.

  echo "Use Nacos API v${nacosApiVersion}"

  if [ "$nacosApiVersion" == "1" ]; then
    namespacesResponse="$(curl -s "${NACOS_SERVER_URL}/v1/console/namespaces?accessToken=${NACOS_ACCESS_TOKEN}")"
  elif [ "$nacosApiVersion" == "3" ]; then
    namespacesResponse="$(curl -s "${NACOS_SERVER_URL}/v3/admin/core/namespace/list?accessToken=${NACOS_ACCESS_TOKEN}")"
  fi
  if grep -q "\"namespace\":\"${NACOS_NS}\"" <<<"$namespacesResponse"; then
    echo "  Namespace ${NACOS_NS} already exists in Nacos."
  else
    echo "  Creating namespace ${NACOS_NS}..."
    if [ "$nacosApiVersion" == "1" ]; then
      statusCode="$(curl -s -o /dev/null -w "%{http_code}" "${NACOS_SERVER_URL}/v1/console/namespaces?accessToken=${NACOS_ACCESS_TOKEN}" --data-urlencode "customNamespaceId=${NACOS_NS}" --data-urlencode "namespaceName=${NACOS_NS}")"
    elif [ "$nacosApiVersion" == "3" ]; then
      statusCode="$(curl -s -o /dev/null -w "%{http_code}" "${NACOS_SERVER_URL}/v3/admin/core/namespace?accessToken=${NACOS_ACCESS_TOKEN}" --data-urlencode "namespaceId=${NACOS_NS}" --data-urlencode "namespaceName=${NACOS_NS}")"
    fi
    if [ $statusCode -ne 200 ]; then
      echo "  Creating namespace ${NACOS_NS} in nacos failed with $statusCode."
      exit -1
    fi
  fi

  if [ "$NACOS_USE_RANDOM_DATA_ENC_KEY" == "N" ]; then
    echo "  Fixed data encryption key is used. Skip config overwriting check."
  else
    # Even the namespace is just created, there might be some dangling config items in it if the namespace itself was delete before without cleaning all the configs first.
    echo "  Checking existed configs in namespace ${NACOS_NS}..."
    if [ "$nacosApiVersion" == "1" ]; then
      statusCode="$(curl -s -o /dev/null -w "%{http_code}" "${NACOS_SERVER_URL}/v2/cs/config?accessToken=${NACOS_ACCESS_TOKEN}&namespaceId=${NACOS_NS}&dataId=secrets.__names__&group=DEFAULT_GROUP")"
    elif [ "$nacosApiVersion" == "3" ]; then
      statusCode="$(curl -s -o /dev/null -w "%{http_code}" "${NACOS_SERVER_URL}/v3/admin/cs/config?accessToken=${NACOS_ACCESS_TOKEN}&namespaceId=${NACOS_NS}&dataId=secrets.__names__&groupName=DEFAULT_GROUP")"
    fi
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
}

checkNacos3ApiCompatibility() {
  if [ "$nacosApiVersion" != "3" ]; then
    return
  fi
  url="${NACOS_SERVER_URL}/v1/cs/configs?accessToken=${NACOS_ACCESS_TOKEN}&namespaceId=${NACOS_NS}&dataId=unknown-config-cd60cd4c&group=DEFAULT_GROUP&search=blur&pageNo=1&pageSize=10"
  statusCode="$(curl -s -o /dev/null -w "%{http_code}" "$url")"
  if [ $statusCode -eq 410 ]; then
    echo "
Nacos 3.x isn't fully supported yet.
  
If you do want to use Nacos 3.x, please add the following property into its application.properties file:
  nacos.core.api.compatibility.console.enabled=true
"
    exit -1
  elif [ $statusCode -ne 200 ]; then
    echo "Unexpected status code $statusCode got from $url"
    echo "Something might be wrong. But we can continue and keep an eye on it."
  fi
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
      cat /dev/urandom | tr -dc '[:graph:]' | head -c 32 >nacos.key
    else
      echo -n "$NACOS_DATA_ENC_KEY" >nacos.key
    fi
  else
    echo "  Data encryption key already exists."
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
