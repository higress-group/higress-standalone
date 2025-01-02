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

  if [ "$CONFIG_STORAGE" == "nacos" ]; then
    mkdir -p ./log/nacos
    chmod a+w ./log/nacos
  fi
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
      && openssl x509 -req -days 36500 -in gateway-cert.csr -sha256 -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial -out gateway-cert.pem -extensions v3_req -extfile gateway.cfg > /dev/null 2>&1
    checkExitCode "Generating certificate for gateway fails with $?"
    chmod a+r gateway-key.pem
  fi
}

initializeGateway() {
  echo "Initializing gateway configurations..."

  mkdir -p $VOLUMES_ROOT/gateway/certs && cd "$_"
  cp $VOLUMES_ROOT/pilot/cacerts/root-cert.pem ./root-cert.pem
  cp $VOLUMES_ROOT/pilot/cacerts/gateway-cert.pem ./cert-chain.pem
  cp $VOLUMES_ROOT/pilot/cacerts/gateway-key.pem ./key.pem
  cat $VOLUMES_ROOT/pilot/cacerts/ca-cert.pem >>./cert-chain.pem

  mkdir -p $VOLUMES_ROOT/gateway/podinfo && cd "$_"
  cat <<EOF >./labels
app="higress-gateway"
higress="higress-system-higress-gateway"
EOF

  mkdir -p $VOLUMES_ROOT/gateway/istio/data

  mkdir -p $VOLUMES_ROOT/gateway/log
  touch $VOLUMES_ROOT/gateway/log/access.log
}

initializePrometheus() {
  echo "Initializing Prometheus configurations..."

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

initializePromtail() {
  echo "Initializing Promtail configurations..."

  mkdir -p $VOLUMES_ROOT/promtail/config && cd "$_"
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
  
  mkdir -p $VOLUMES_ROOT/promtail/data
  chmod a+rwx $VOLUMES_ROOT/promtail/data
}

initializeLoki() {
  echo "Initializing Loki configurations..."

  mkdir -p $VOLUMES_ROOT/loki/config && cd "$_"
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
  cat <<EOF >./runtime-config.yaml
{}
EOF

  mkdir -p $VOLUMES_ROOT/loki/data/
  chmod a+rwx $VOLUMES_ROOT/loki/data/
}

initializeGrafana() {
  echo "Initializing Grafana configurations..."

  mkdir -p $VOLUMES_ROOT/grafana/config && cd "$_"
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

  mkdir -p $VOLUMES_ROOT/grafana/lib
  chmod a+rwx $VOLUMES_ROOT/grafana/lib
}

initializeO11y() {
  initializePrometheus
  initializePromtail
  initializeLoki
  initializeGrafana
}

initializeConfigStorage
initializeApiServer
initializeController
initializePilot
initializeGateway
initializeO11y
