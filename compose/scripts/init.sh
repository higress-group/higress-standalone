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

publishConfig() {
  # $1 namespace
  # $2 configType: plural
  # $3 configName
  # $4 content
  # $5 skipWhenExisted
  case $CONFIG_STORAGE in
    nacos)
      publishNacosConfig "$@"
      ;;
    file)
      publishFileConfig "$@"
      ;;
    *)
      printf "  Unknown storage type: %s\n" "$CONFIG_STORAGE"
      exit -1
      ;;
  esac
}

publishNacosConfig() {
  # $1 namespace
  # $2 configType: plural
  # $3 configName
  # $4 content
  # $5 skipWhenExisted
  local group="$1"
  local dataId="$2.$3"
  local content="$4"
  local skipWhenExisted=$5

  if [ "$skipWhenExisted" == true ]; then
    statusCode=$(curl -s -o /dev/null -w "%{http_code}" "${NACOS_SERVER_URL}/v1/cs/configs?accessToken=${NACOS_ACCESS_TOKEN}&tenant=${NACOS_NS}&dataId=${dataId}&group=${group}")
    if [ $statusCode -eq 200 ]; then
      echo "  Config $group/$dataId already exists in namespace ${NACOS_NS}"
      return 0
    elif [ $statusCode -ne 404 ]; then
      echo "  Checking config $group/$dataId in tenant ${NACOS_NS} failed with $statusCode"
      exit -1
    fi
  fi

  statusCode="$(curl -s -o /dev/null -w "%{http_code}" "${NACOS_SERVER_URL}/v1/cs/configs?accessToken=${NACOS_ACCESS_TOKEN}" --data-urlencode "tenant=${NACOS_NS}" --data-urlencode "dataId=${dataId}" --data-urlencode "group=${group}" --data-urlencode "content=${content}")"
  if [ $statusCode -ne 200 ]; then
    echo "  Publishing config ${group}/${dataId} in tenant ${NACOS_NS} failed with $statusCode"
    exit -1 
  fi
  return 0
}

publishFileConfig() {
  # $1 namespace: ignored. only for alignment
  # $2 configType: plural
  # $3 configName
  # $4 content
  # $5 skipWhenExisted
  local configDir="${FILE_ROOT_DIR}/$2"
  local configFile="${configDir}/$3.yaml"
  local content="$4"
  local skipWhenExisted=$5

  if [ "$skipWhenExisted" == true ] && [ -f "$configFile" ]; then
      echo "  Config file [$configFile] already exists"
      return 0
  fi

  mkdir -p "$configDir"
  checkExitCode "  Creating config directory [$configDir] fails with $?"
  echo "$content" > "$configFile"
  return 0
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

  if grep -q "\"namespace\":\"${NACOS_NS}\"" <<< "$(curl -s "${NACOS_SERVER_URL}/v1/console/namespaces?accessToken=${NACOS_ACCESS_TOKEN}")"; then
    echo "  Namespace ${NACOS_NS} already exists in Nacos."
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

  if [ ! -f ca.key ] || [ ! -f ca.crt ]; then
    echo "  Generating CA certificate...";
    openssl req -nodes -new -x509 -days 36500 -keyout ca.key -out ca.crt -subj "/CN=higress-root-ca/O=higress" > /dev/null 2>&1
    checkExitCode "  Generating CA certificate for API server fails with $?";
  else
    echo "  CA certificate already exists.";
  fi
  if [ ! -f server.key ] || [ ! -f server.crt ]; then
    echo "  Generating server certificate..."
    openssl req -out server.csr -new -newkey rsa:$RSA_KEY_LENGTH -nodes -keyout server.key -subj "/CN=higress-api-server/O=higress" > /dev/null 2>&1 \
      && openssl x509 -req -days 36500 -in server.csr -CA ca.crt -CAkey ca.key -set_serial 01 -sha256 -out server.crt > /dev/null 2>&1
    checkExitCode "  Generating server certificate fails with $?";
  else
    echo "  Server certificate already exists.";
  fi
  if [ ! -f nacos.key ]; then
    echo "  Generating data encryption key..."
    if [ -z "$NACOS_DATA_ENC_KEY" ]; then
      cat /dev/urandom | tr -dc '[:graph:]' | head -c 32 > nacos.key
    else
      echo -n "$NACOS_DATA_ENC_KEY" > nacos.key
    fi
  else
    echo "  Client certificate already exists.";
  fi
  if [ ! -f client.key ] || [ ! -f client.crt ]; then
    echo "  Generating client certificate..."
    openssl req -out client.csr -new -newkey rsa:$RSA_KEY_LENGTH -nodes -keyout client.key -subj "/CN=higress/O=system:masters" > /dev/null 2>&1 \
      && openssl x509 -req -days 36500 -in client.csr -CA ca.crt -CAkey ca.key -set_serial 02 -sha256 -out client.crt > /dev/null 2>&1
    checkExitCode "  Generating client certificate fails with $?";
  else
    echo "  Client certificate already exists.";
  fi

  CLIENT_CERT=$(cat client.crt | base64 -w 0)
  CLIENT_KEY=$(cat client.key | base64 -w 0)

  if [ ! -f $VOLUMES_ROOT/kube/config ]; then
    echo "  Generating kubeconfig..."
    mkdir -p $VOLUMES_ROOT/kube
    cat <<EOF > $VOLUMES_ROOT/kube/config
apiVersion: v1
kind: Config
clusters:
  - name: higress
    cluster:
      server: https://apiserver:8443
      insecure-skip-tls-verify: true
users:
  - name: higress-admin
    user:
      client-certificate-data: ${CLIENT_CERT}
      client-key-data: ${CLIENT_KEY}
contexts:
  - name: higress
    context:
      cluster: higress
      user: higress-admin
preferences: {}
current-context: higress
EOF
  else
    echo "  kubeconfig already exists."
  fi
}

initializeController() {
  echo "Initializing controller configurations..."

  mkdir -p $VOLUMES_ROOT/controller && cd "$_"

  mkdir -p ./log/nacos
  chmod a+w ./log/nacos
}

initializePilot() {
  echo "Initializing pilot configurations..."

  mkdir -p $VOLUMES_ROOT/pilot/cacerts && cd "$_"

  if [ ! -f root-key.pem ] || [ ! -f root-cert.pem ]; then
    openssl req -newkey rsa:$RSA_KEY_LENGTH -nodes -keyout root-key.pem -x509 -days 36500 -out root-cert.pem > /dev/null 2>&1 <<EOF
CN
Shanghai
Shanghai
Higress
Gateway
Root CA
rootca@higress.io


EOF
    checkExitCode "  Generating Root CA certificate for pilot fails with $?"
  fi

  if [ ! -f ca-key.pem ] || [ ! -f ca-cert.pem ]; then
    cat <<EOF > ca.cfg
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = CN
ST = Shanghai
L = Shanghai
O = Higress
CN = Higress CA

[v3_req]
keyUsage = keyCertSign
basicConstraints = CA:TRUE
subjectAltName = @alt_names

[alt_names]
DNS.1 = ca.higress.io
EOF
    openssl genrsa -out ca-key.pem $RSA_KEY_LENGTH > /dev/null \
      && openssl req -new -key ca-key.pem -out ca-cert.csr -config ca.cfg -batch -sha256 > /dev/null 2>&1 \
      && openssl x509 -req -days 36500 -in ca-cert.csr -sha256 -CA root-cert.pem -CAkey root-key.pem -CAcreateserial -out ca-cert.pem -extensions v3_req -extfile ca.cfg > /dev/null 2>&1
    checkExitCode "Generating intermedia CA certificate for pilot fails with $?"
    cp ca-cert.pem cert-chain.pem > /dev/null
    chmod a+r ca-key.pem
    rm ./*csr > /dev/null
  fi

  if [ ! -f gateway-key.pem ] || [ ! -f gateway-cert.pem ]; then
    cat <<EOF > gateway.cfg
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = CN
ST = Shanghai
L = Shanghai
O = Higress
CN = Higress Gateway

[v3_req]
keyUsage = digitalSignature, keyEncipherment
subjectAltName = URI:spiffe://cluster.local/ns/higress-system/sa/higress-gateway
EOF
    openssl genrsa -out gateway-key.pem $RSA_KEY_LENGTH > /dev/null \
      && openssl req -new -key gateway-key.pem -out gateway-cert.csr -config gateway.cfg -batch -sha256 > /dev/null 2>&1 \
      && openssl x509 -req -days 365 -in gateway-cert.csr -sha256 -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial -out gateway-cert.pem -extensions v3_req -extfile gateway.cfg > /dev/null 2>&1
    checkExitCode "Generating certificate for gateway fails with $?"
    chmod a+r gateway-key.pem
  fi

  read -r -d '' content << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    app: higress-gateway
    higress: higress-system-higress-gateway
  name: higress-config
  namespace: higress-system
data:
  mesh: |-
    accessLogEncoding: TEXT
    accessLogFile: /dev/stdout
    accessLogFormat: |
      {"authority":"%REQ(:AUTHORITY)%","bytes_received":"%BYTES_RECEIVED%","bytes_sent":"%BYTES_SENT%","downstream_local_address":"%DOWNSTREAM_LOCAL_ADDRESS%","downstream_remote_address":"%DOWNSTREAM_REMOTE_ADDRESS%","duration":"%DURATION%","istio_policy_status":"%DYNAMIC_METADATA(istio.mixer:status)%","method":"%REQ(:METHOD)%","path":"%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%","protocol":"%PROTOCOL%","request_id":"%REQ(X-REQUEST-ID)%","requested_server_name":"%REQUESTED_SERVER_NAME%","response_code":"%RESPONSE_CODE%","response_flags":"%RESPONSE_FLAGS%","route_name":"%ROUTE_NAME%","start_time":"%START_TIME%","trace_id":"%REQ(X-B3-TRACEID)%","upstream_cluster":"%UPSTREAM_CLUSTER%","upstream_host":"%UPSTREAM_HOST%","upstream_local_address":"%UPSTREAM_LOCAL_ADDRESS%","upstream_service_time":"%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%","upstream_transport_failure_reason":"%UPSTREAM_TRANSPORT_FAILURE_REASON%","user_agent":"%REQ(USER-AGENT)%","x_forwarded_for":"%REQ(X-FORWARDED-FOR)%"}
    configSources:
    - address: xds://controller:15051
    defaultConfig:
      disableAlpnH2: true
      discoveryAddress: pilot:15012
      proxyStatsMatcher:
        inclusionRegexps:
        - .*
    dnsRefreshRate: 200s
    enableAutoMtls: false
    enablePrometheusMerge: true
    ingressControllerMode: "OFF"
    protocolDetectionTimeout: 100ms
    rootNamespace: higress-system
    trustDomain: cluster.local
  meshNetworks: 'networks: {}'
EOF
  publishConfig "higress-system" "configmaps" "higress-config" "$content" true
}

initializeGateway() {
  echo "Initializing gateway configurations..."

  mkdir -p $VOLUMES_ROOT/gateway/certs && cd "$_"
  cp $VOLUMES_ROOT/pilot/cacerts/root-cert.pem ./root-cert.pem
  cp $VOLUMES_ROOT/pilot/cacerts/gateway-cert.pem ./cert-chain.pem
  cp $VOLUMES_ROOT/pilot/cacerts/gateway-key.pem ./key.pem

  mkdir -p $VOLUMES_ROOT/gateway/podinfo && cd "$_"
  echo 'higress="higress-system-higress-gateway"' > ./labels

  mkdir -p $VOLUMES_ROOT/gateway/istio/data
}

initializeMcpBridge() {
  echo "Initializing McpBridge resource..."

  read -r -d '' mcpbridgeContent << EOF
apiVersion: networking.higress.io/v1
kind: McpBridge
metadata:
  creationTimestamp: "$(now)"
  name: default
  namespace: higress-system
spec:
  registries:
EOF

  if [ "$CONFIG_STORAGE" == "nacos" ]; then
    if [[ "$NACOS_SERVER_URL" =~ ^http://([a-zA-Z0-9.]+?)(:([0-9]+))/nacos$ ]]; then
      NACOS_SERVER_DOMAIN="${BASH_REMATCH[1]}"
      NACOS_SERVER_PORT="${BASH_REMATCH[3]}"
    else
      echo "  Unable to parse Nacos server URL. Skip creating the McpBridge resource"
      return
    fi

    nacosAuthSecretName=""

    if [ -n "$NACOS_USERNAME" ] && [ -n "$NACOS_PASSWORD" ]; then
      nacosAuthSecretName="nacos-auth-default"
      read -r -d '' nacosAuthSecretContent << EOF
apiVersion: v1
kind: Secret
metadata:
  creationTimestamp: "$(now)"
  name: ${nacosAuthSecretName}
  namespace: higress-system
data:
  nacosUsername: $(echo -n "${NACOS_USERNAME}" | base64 -w 0)
  nacosPassword: $(echo -n "${NACOS_PASSWORD}" | base64 -w 0)
type: Opaque
EOF
      publishConfig "higress-system" "secrets" "${nacosAuthSecretName}" "$nacosAuthSecretContent"
    fi

    read -r -d '' mcpbridgeContent << EOF
${mcpbridgeContent}
  - domain: ${NACOS_SERVER_DOMAIN}
    nacosGroups:
    - DEFAULT_GROUP
    nacosNamespaceId: ""
    name: nacos
    port: ${NACOS_SERVER_PORT:-80}
    type: nacos2
    authSecretName: "${nacosAuthSecretName}"
EOF
  fi

  publishConfig "higress-system" "mcpbridges" "default" "$mcpbridgeContent"
}

initializeConsole() {
  echo "Initializing console configurations..."

  read -r -d '' content << EOF
apiVersion: v1 
kind: ConfigMap
metadata:
  creationTimestamp: "$(now)"
  name: higress-console
  namespace: higress-system
data:
  mode: standalone
EOF
  publishConfig "higress-system" "configmaps" "higress-console" "$content"

  read -r -d '' content << EOF
apiVersion: v1
data:
  iv: $(cat /dev/urandom | tr -dc '[:graph:]' | fold -w 16 | head -n 1 | tr -d '\n' | base64 -w 0)
  key: $(cat /dev/urandom | tr -dc '[:graph:]' | fold -w 32 | head -n 1 | tr -d '\n' | base64 -w 0)
kind: Secret
metadata:
  creationTimestamp: "$(now)"
  name: higress-console
  namespace: higress-system
type: Opaque
EOF
  publishConfig "higress-system" "secrets" "higress-console" "$content"
}

initializeConfigStorage
initializeApiServer
initializeController
initializePilot
initializeGateway
initializeMcpBridge
initializeConsole
