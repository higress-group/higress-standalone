#! /bin/bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VOLUMES_ROOT="/mnt/volumes"

API_SERVER_BASE_URL="https://apiserver:8443"

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
  # $2 configGroupVersion
  # $3 configType: plural
  # $4 configName
  local namespace="$1"
  local configGroupVersion="$2"
  local configType="$3"
  local configName="$4"

  local uriPrefix="/api"
  if [[ "$configGroupVersion" == *"/"* ]]; then
    uriPrefix="/apis"
  fi
  local url;
  if [ -z "$namespace" ]; then
    url="${API_SERVER_BASE_URL}${uriPrefix}/${configGroupVersion}/${configType}/${configName}"
  else
    url="${API_SERVER_BASE_URL}${uriPrefix}/${configGroupVersion}/namespaces/${namespace}/${configType}/${configName}"
  fi
  statusCode=$(curl -s -o /dev/null -w "%{http_code}" "${url}" -k)
  if [ $statusCode -eq 200 ]; then
    return 0
  elif [ $statusCode -eq 404 ]; then
    return -1
  else
    echo "  Checking config ${configType}.${configName} in namespace ${namespace} failed with ${statusCode}"
    exit -1
  fi
}

getConfig() {
  # $1 namespace
  # $2 configGroupVersion
  # $3 configType: plural
  # $4 configName
  local namespace="$1"
  local configGroupVersion="$2"
  local configType="$3"
  local configName="$4"

  config=""
  local uriPrefix="/api"
  if [[ "$configGroupVersion" == *"/"* ]]; then
    uriPrefix="/apis"
  fi
  local url;
  if [ -z "$namespace" ]; then
    url="${API_SERVER_BASE_URL}${uriPrefix}/${configGroupVersion}/${configType}/${configName}"
  else
    url="${API_SERVER_BASE_URL}${uriPrefix}/${configGroupVersion}/namespaces/${namespace}/${configType}/${configName}"
  fi
  local tmpFile=$(mktemp /tmp/higress-precheck-config.XXXXXXXXX.cfg)
  local statusCode=$(curl -s -o "$tmpFile" -w "%{http_code}" "${url}" -k -H "Accept: application/yaml")
  if [ $statusCode -eq 200 ]; then
    config=$(cat "$tmpFile")
    rm "$tmpFile"
    return 0
  elif [ $statusCode -eq 404 ]; then
    config=""
    return -1
  else
    echo ${1:-"  Getting config ${configType}.${configName} in namespace ${namespace} failed with ${statusCode}"}
    exit -1
  fi
}

publishConfig() {
  # $1 namespace
  # $2 configGroupVersion
  # $3 configType: plural
  # $4 configName
  # $5 content
  local namespace="$1"
  local configGroupVersion="$2"
  local configType="$3"
  local configName="$4"
  local content="$5"

  local uriPrefix="/api"
  if [[ "$configGroupVersion" == *"/"* ]]; then
    uriPrefix="/apis"
  fi
  local url;
  if [ -z "$namespace" ]; then
    url="${API_SERVER_BASE_URL}${uriPrefix}/${configGroupVersion}/${configType}"
  else
    url="${API_SERVER_BASE_URL}${uriPrefix}/${configGroupVersion}/namespaces/${namespace}/${configType}"
  fi
  statusCode="$(curl -s -o /dev/null -w "%{http_code}" "$url" -k -X POST -H "Content-Type: application/yaml" -d "$content")"
  if [ $statusCode -ne 201 ]; then
    echo "  Publishing config ${configType}.${configName} to namespace ${namespace} failed with ${statusCode}"
    exit -1
  fi
}

checkStorage() {
  echo "Checking config storage configurations..."

  read -r -d '' mcpbridgeContent <<EOF
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

    read -r -d '' mcpbridgeContent <<EOF
${mcpbridgeContent}
  - domain: ${NACOS_SERVER_DOMAIN}
    nacosGroups:
    - DEFAULT_GROUP
    nacosNamespaceId: ""
    name: nacos
    port: ${NACOS_SERVER_PORT:-80}
    type: nacos2
EOF

    nacosAuthSecretName=""

    if [ -n "$NACOS_USERNAME" ] && [ -n "$NACOS_PASSWORD" ]; then
      nacosAuthSecretName="nacos-auth-default"
      checkConfigExists "higress-system" "v1" "secrets" "$nacosAuthSecretName"
      if [ $? -ne 0 ]; then
        echo "  The Secret resource \"${nacosAuthSecretName}\" doesn't exist. Create it now..."
        read -r -d '' nacosAuthSecretContent <<EOF
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
        publishConfig "higress-system" "v1" "secrets" "${nacosAuthSecretName}" "$nacosAuthSecretContent"
        read -r -d '' mcpbridgeContent <<EOF
${mcpbridgeContent}
    authSecretName: "${nacosAuthSecretName}"
EOF
      fi
    fi
  fi

  checkConfigExists "higress-system" "networking.higress.io/v1" "mcpbridges" "default"
  if [ $? -ne 0 ]; then
    echo "  The McpBridge resource \"default\" doesn't exist. Create it now..."
    publishConfig "higress-system" "networking.higress.io/v1" "mcpbridges" "default" "$mcpbridgeContent" true
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

  checkConfigExists "higress-system" "v1" "configmaps" "higress-config"
  if [ $? -ne 0 ]; then
    echo "  The ConfigMap resource \"higress-config\" doesn't exist. Create it now..."
    read -r -d '' content <<EOF
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
    - address: k8s://
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
    publishConfig "higress-system" "v1" "configmaps" "higress-config" "$content"
  fi

  mkdir -p $VOLUMES_ROOT/pilot/config && cd "$_"
  getConfig "higress-system" "v1" "configmaps" "higress-config"
  checkExitCode "  The ConfigMap resource of 'higress-config' doesn't exist."
  fileNames=$(yq '.data | keys | .[]' <<<"$config")
  if [ -z "$fileNames" ]; then
    echo "  Missing required files in higress-config ConfigMap."
    exit -1
  fi
  IFS=$'\n'
  for fileName in $fileNames; do
    if [ -z "$fileName" ]; then
      continue
    fi
    echo "$config" | yq ".data.$fileName" >"./$fileName"
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

  checkConfigExists "higress-system" "v1" "secrets" "higress-console"
  if [ $? -ne 0 ]; then
    echo "  The ConfigMap resource \"higress-console\" doesn't exist. Create it now..."
    read -r -d '' content <<EOF
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
    publishConfig "higress-system" "v1" "secrets" "higress-console" "$content"
  fi

  checkConfigExists "higress-system" "v1" "configmaps" "higress-console"
  if [ $? -ne 0 ]; then
    echo "  The Secret resource \"higress-console\" doesn't exist. Create it now..."
    read -r -d '' content <<EOF
apiVersion: v1 
kind: ConfigMap
metadata:
  creationTimestamp: "$(now)"
  name: higress-console
  namespace: higress-system
data:
  mode: standalone
EOF
    publishConfig "higress-system" "v1" "configmaps" "higress-console" "$content"
  fi
}

checkGatewayApi() {
  echo "Checking Gateway API configurations..."

  checkConfigExists "higress-system" "v1" "services" "higress-gateway"
  if [ $? -ne 0 ]; then
    echo "  The Service resource \"higress-gateway\" doesn't exist. Create it now..."
    read -r -d '' content <<EOF
apiVersion: v1
kind: Service
metadata:
  labels:
    higress: higress-system-higress-gateway
  name: higress-gateway
  namespace: higress-system
spec:
  ports:
  - name: http2
    port: 80
    protocol: TCP
    targetPort: 80
  - name: https
    port: 443
    protocol: TCP
    targetPort: 443
  selector:
    higress: higress-system-higress-gateway
  type: LoadBalancer
EOF
    publishConfig "higress-system" "v1" "services" "higress-gateway" "$content"
  fi

  checkConfigExists "" "gateway.networking.k8s.io/v1beta1" "gatewayclasses" "higress-gateway"
  if [ $? -ne 0 ]; then
    echo "  The GatewayClass resource \"higress-gateway\" doesn't exist. Create it now..."
    read -r -d '' content <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: GatewayClass
metadata:
  name: higress-gateway
spec:
  controllerName: "higress.io/gateway-controller"
EOF
    publishConfig "" "gateway.networking.k8s.io/v1beta1" "gatewayclasses" "higress-gateway" "$content"
  fi

  checkConfigExists "higress-system" "gateway.networking.k8s.io/v1beta1" "gateways" "higress-gateway"
  if [ $? -ne 0 ]; then
    echo "  The Gateway resource \"higress-gateway\" doesn't exist. Create it now..."
    read -r -d '' content <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: higress-gateway
  namespace: higress-system
spec:
  gatewayClassName: higress-gateway
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
  - name: https
    port: 443
    protocol: HTTPS
    allowedRoutes:
      namespaces:
        from: All
EOF
    publishConfig "higress-system" "gateway.networking.k8s.io/v1beta1" "gateways" "higress-gateway" "$content"
  fi
}

checkStorage
checkPilot
checkGateway
checkConsole
checkGatewayApi
