#! /bin/bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VOLUMES_ROOT="/mnt/volumes"
RSA_KEY_LENGTH=4096

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
  local url
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
  local url
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
  local url
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
  - domain: console.svc
    name: higress-console
    port: 8080
    type: dns
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

  renewPilotCerts
  checkHigressConfig
}

renewPilotCerts() {
  local pilotStatusCode=$(curl -s -o /dev/null -w "%{http_code}" "http://pilot.svc:8080/ready" -k)
  if [ "$pilotStatusCode" != "000" ]; then
    echo "  Pilot is running. Skip certificate renewal."
    return
  fi
  local gatewayStatusCode=$(curl -s -o /dev/null -w "%{http_code}" "http://gateway.svc:15021/healthz/ready" -k)
  if [ "$gatewayStatusCode" != "000" ]; then
    echo "  Gateway is running. Skip certificate renewal."
    return
  fi
  
  mkdir -p $VOLUMES_ROOT/pilot/cacerts && cd "$_"

  openssl req -newkey rsa:$RSA_KEY_LENGTH -nodes -keyout root-key.pem -x509 -days 36500 -out root-cert.pem >/dev/null 2>&1 <<EOF
CN
Shanghai
Shanghai
Higress
Gateway
Root CA
rootca@higress.io


EOF
  checkExitCode "  Generating Root CA certificate for pilot fails with $?"

  cat <<EOF >ca.cfg
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
  openssl genrsa -out ca-key.pem $RSA_KEY_LENGTH >/dev/null &&
    openssl req -new -key ca-key.pem -out ca-cert.csr -config ca.cfg -batch -sha256 >/dev/null 2>&1 &&
    openssl x509 -req -days 36500 -in ca-cert.csr -sha256 -CA root-cert.pem -CAkey root-key.pem -CAcreateserial -out ca-cert.pem -extensions v3_req -extfile ca.cfg >/dev/null 2>&1
  checkExitCode "Generating intermedia CA certificate for pilot fails with $?"
  cp ca-cert.pem cert-chain.pem >/dev/null
  chmod a+r ca-key.pem
  rm ./*csr >/dev/null

  cat <<EOF >gateway.cfg
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
  openssl genrsa -out gateway-key.pem $RSA_KEY_LENGTH >/dev/null &&
    openssl req -new -key gateway-key.pem -out gateway-cert.csr -config gateway.cfg -batch -sha256 >/dev/null 2>&1 &&
    openssl x509 -req -days 36500 -in gateway-cert.csr -sha256 -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial -out gateway-cert.pem -extensions v3_req -extfile gateway.cfg >/dev/null 2>&1
  checkExitCode "Generating certificate for gateway fails with $?"
  chmod a+r gateway-key.pem
}


checkHigressConfig() {
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
  higress: |-
    mcpServer:
      enable: false
      sse_path_suffix: /sse
      redis:
        address: redis-address:6379
        username: ""
        password: ""
        db: 0
      match_list: []
      servers: []
    downstream:
      connectionBufferLimits: 32768
      http2:
        initialConnectionWindowSize: 1048576
        initialStreamWindowSize: 65535
        maxConcurrentStreams: 100
      idleTimeout: 180
      maxRequestHeadersKb: 60
      routeTimeout: 0
    upstream:
      connectionBufferLimits: 10485760
      idleTimeout: 10
  mesh: |-
    accessLogEncoding: TEXT
    accessLogFile: /var/log/proxy/access.log
    accessLogFormat: |
      {"ai_log":"%FILTER_STATE(wasm.ai_log:PLAIN)%","authority":"%REQ(X-ENVOY-ORIGINAL-HOST?:AUTHORITY)%","bytes_received":"%BYTES_RECEIVED%","bytes_sent":"%BYTES_SENT%","downstream_local_address":"%DOWNSTREAM_LOCAL_ADDRESS%","downstream_remote_address":"%DOWNSTREAM_REMOTE_ADDRESS%","duration":"%DURATION%","istio_policy_status":"%DYNAMIC_METADATA(istio.mixer:status)%","method":"%REQ(:METHOD)%","path":"%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%","protocol":"%PROTOCOL%","request_id":"%REQ(X-REQUEST-ID)%","requested_server_name":"%REQUESTED_SERVER_NAME%","response_code":"%RESPONSE_CODE%","response_flags":"%RESPONSE_FLAGS%","route_name":"%ROUTE_NAME%","start_time":"%START_TIME%","trace_id":"%REQ(X-B3-TRACEID)%","upstream_cluster":"%UPSTREAM_CLUSTER%","upstream_host":"%UPSTREAM_HOST%","upstream_local_address":"%UPSTREAM_LOCAL_ADDRESS%","upstream_service_time":"%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%","upstream_transport_failure_reason":"%UPSTREAM_TRANSPORT_FAILURE_REASON%","user_agent":"%REQ(USER-AGENT)%","x_forwarded_for":"%REQ(X-FORWARDED-FOR)%"}
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
    mseIngressGlobalConfig:
      enableH3: false
      enableProxyProtocol: false
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

  mkdir -p $VOLUMES_ROOT/gateway/certs && cd "$_"
  cp $VOLUMES_ROOT/pilot/cacerts/root-cert.pem ./root-cert.pem
  cp $VOLUMES_ROOT/pilot/cacerts/gateway-cert.pem ./cert-chain.pem
  cp $VOLUMES_ROOT/pilot/cacerts/gateway-key.pem ./key.pem
  cat $VOLUMES_ROOT/pilot/cacerts/ca-cert.pem >>./cert-chain.pem

  mkdir -p $VOLUMES_ROOT/gateway/podinfo && cd "$_"
  if [ ! -f labels ]; then
    cat <<EOF >./labels
app="higress-gateway"
higress="higress-system-higress-gateway"
EOF
  fi

  mkdir -p $VOLUMES_ROOT/gateway/istio/data

  mkdir -p $VOLUMES_ROOT/gateway/log
  touch $VOLUMES_ROOT/gateway/log/access.log

  checkConfigExists "higress-system" "networking.istio.io/v1alpha3" "envoyfilters" "higress-gateway-global-custom-response"
  if [ $? -ne 0 ]; then
    echo "  The EnvoyFilter resource \"higress-gateway-global-custom-response\" doesn't exist. Create it now..."
    read -r -d '' content <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: higress-gateway-global-custom-response
  namespace: higress-system
  labels:
    app: higress-gateway
    higress: higress-system-higress-gateway
spec:
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: GATEWAY
      listener:
        filterChain:
          filter:
            name: envoy.filters.network.http_connection_manager
    patch:
      operation: INSERT_FIRST
      value:
        name: envoy.filters.http.custom_response
        typed_config:
          '@type': type.googleapis.com/envoy.extensions.filters.http.custom_response.v3.CustomResponse
EOF
    publishConfig "higress-system" "networking.istio.io/v1alpha3" "envoyfilters" "higress-gateway-global-custom-response" "$content"
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

checkPrometheus() {
  echo "Checking Prometheus configurations..."

  mkdir -p $VOLUMES_ROOT/prometheus/config && cd "$_"
  cat <<EOF >./prometheus.yaml
global:
  scrape_interval:     15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: 'prometheus'
    metrics_path: /prometheus/metrics
    static_configs:
    - targets: ['localhost:9090']
  - job_name: 'gateway'
    metrics_path: /stats/prometheus
    static_configs:
    - targets: ['gateway:15020']
      labels:
        container: 'higress-gateway'
        namespace: 'higress-system'
        higress: 'higress-system-higress-gateway'
        pod: 'higress'
EOF

  mkdir -p $VOLUMES_ROOT/prometheus/data
  chmod a+rwx $VOLUMES_ROOT/prometheus/data
}

checkPromtail() {
  echo "Checking Promtail configurations..."

  mkdir -p $VOLUMES_ROOT/promtail/config && cd "$_"
  if [ ! -f promtail.yaml ]; then
    cat <<EOF >./promtail.yaml
server:
  log_level: info
  http_listen_port: 3101

clients:
- url: http://loki:3100/loki/api/v1/push

positions:
  filename: /var/promtail/promtail-positions.yaml
target_config:
  sync_period: 10s
scrape_configs:
- job_name: access-logs
  static_configs:
  - targets:
    - localhost
    labels:
      __path__: /var/log/proxy/access.log
  pipeline_stages:
  - json:
      expressions:
        authority:
        method:
        path:
        protocol:
        request_id:
        response_code:
        response_flags:
        route_name:
        trace_id:
        upstream_cluster:
        upstream_host:
        upstream_transport_failure_reason:
        user_agent:
        x_forwarded_for:
  - labels:
      authority:
      method:
      path:
      protocol:
      request_id:
      response_code:
      response_flags:
      route_name:
      trace_id:
      upstream_cluster:
      upstream_host:
      upstream_transport_failure_reason:
      user_agent:
      x_forwarded_for:
  - timestamp:
      source: timestamp
      format: RFC3339Nano
EOF
  fi

  mkdir -p $VOLUMES_ROOT/promtail/data
  chmod a+rwx $VOLUMES_ROOT/promtail/data
}

checkLoki() {
  echo "Checking Loki configurations..."

  mkdir -p $VOLUMES_ROOT/loki/config && cd "$_"
  if [ ! -f config.yaml ]; then
    cat <<EOF >./config.yaml
auth_enabled: false
common:
  compactor_address: 'loki'
  path_prefix: /var/loki
  replication_factor: 1
  storage:
    filesystem:
      chunks_directory: /var/loki/chunks
      rules_directory: /var/loki/rules
frontend:
  scheduler_address: ""
frontend_worker:
  scheduler_address: ""
index_gateway:
  mode: ring
limits_config:
  max_cache_freshness_per_query: 10m
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  split_queries_by_interval: 15m
memberlist:
  join_members:
  - loki
query_range:
  align_queries_with_step: true
ruler:
  storage:
    type: local
runtime_config:
  file: /etc/loki/config/runtime-config.yaml
schema_config:
  configs:
  - from: "2022-01-11"
    index:
      period: 24h
      prefix: loki_index_
    object_store: filesystem
    schema: v12
    store: boltdb-shipper
server:
  http_listen_port: 3100
  grpc_listen_port: 9095
storage_config:
  hedging:
    at: 250ms
    max_per_second: 20
    up_to: 3
tracing:
  enabled: false
EOF
  fi
  if [ ! -f runtime-config.yaml ]; then
    cat <<EOF >./runtime-config.yaml
{}
EOF
  fi

  mkdir -p $VOLUMES_ROOT/loki/data/
  chmod a+rwx $VOLUMES_ROOT/loki/data/
}

checkGrafana() {
  echo "Checking Grafana configurations..."

  mkdir -p $VOLUMES_ROOT/grafana/config && cd "$_"
  if [ ! -f grafana.ini ]; then
    cat <<EOF >./grafana.ini
[server]
protocol=http
domain=localhost
root_url="%(protocol)s://%(domain)s/grafana"
serve_from_sub_path=true

[auth]
disable_login_form=true
disable_signout_menu=true

[auth.anonymous]
enabled=true
org_name=Main Org.
org_role=Viewer

[users]
default_theme=light
viewers_can_edit=true

[security]
allow_embedding=true
EOF
  fi

  mkdir -p $VOLUMES_ROOT/grafana/lib
  chmod a+rwx $VOLUMES_ROOT/grafana/lib
}

checkO11y() {
  checkPrometheus
  checkPromtail
  checkLoki
  checkGrafana
}

checkStorage
checkPilot
checkGateway
checkConsole
checkGatewayApi
checkO11y
