#!/usr/bin/env bash
#
# End-to-end verification for higress-group/higress#4538.
#
# Mode "chain" (default): spins up an isolated Nacos server plus the API
# server built from the current working tree, drives three deletion sequences
# through the real Nacos HTTP API (as the Nacos console would) and consumes
# the real Kubernetes watch stream exposed by the API server:
#
#   1. clean delete:             ADDED(A) -> delete -> DELETED(A), API GET 404
#   2. invalid overwrite:        ADDED(A) -> content overwritten with "x" ->
#                                at least one full refresh -> delete ->
#                                DELETED(A), API GET 404
#   3. valid update then delete: ADDED(A) -> MODIFIED(B) -> delete ->
#                                DELETED(B) (never A), API GET 404
#
# Mode "gateway": runs the full standalone acceptance against a real Higress
# 2.2.3 data plane (controller, pilot, gateway) pinned to the versions from
# the issue report, with the API server swapped for the given prebuilt image
# (higress-4538/apiserver:<baseline|fix>). It verifies clean delete and the
# invalid-overwrite delete through the HTTP route, the gateway config_dump,
# a gateway restart and a same-name recreation.
#
# Every wait is bounded (60 seconds); on timeout the script collects the
# container logs and fails. No credentials are used or printed anywhere.
#
# Usage:
#   ./verify.sh [--keep]
#   ./verify.sh gateway <baseline|fix> [--keep]
#   --keep  leave the compose stack running after the run (for debugging).

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

REPO_COMPOSE_DIR="$(cd "$BASE_DIR/../../../.." && pwd)/compose"

MODE="chain"
VARIANT=""
KEEP=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
  gateway) MODE="gateway" ;;
  --keep) KEEP=true ;;
  *) ARGS+=("$arg") ;;
  esac
done
if [ "$MODE" = "gateway" ]; then
  VARIANT="${ARGS[0]:-}"
  [ -n "$VARIANT" ] || { echo "usage: verify.sh gateway <baseline|fix> [--keep]" >&2; exit 2; }
elif [ "${ARGS[0]:-}" != "" ]; then
  echo "usage: verify.sh [--keep] | verify.sh gateway <baseline|fix> [--keep]" >&2
  exit 2
fi

RUNTIME_DIR="$BASE_DIR/.runtime"
CERTS_DIR="$BASE_DIR/certs"
EVENTS_FILE="$RUNTIME_DIR/events.jsonl"
LOG_DIR="$RUNTIME_DIR/logs"
STOP_WATCH_FILE="$RUNTIME_DIR/stop-watch"

NAMESPACE="higress-system"
GROUP="$NAMESPACE"
DATA_ID="ingresses.canary-test"
INGRESS_NAME="canary-test"

# Production refresh interval (NACOS_LIST_REFRESH_INTERVAL_SECS default).
REFRESH_INTERVAL_SECS=10
WAIT_TIMEOUT_SECS=60

WATCHER_PID=""
COMPOSE_FILE="$BASE_DIR/compose.yaml"

# Chain-mode defaults; the gateway mode overrides them below.
NACOS_URL="http://localhost:18488/nacos"
API_URL="https://localhost:18443"

if [ "$MODE" = "gateway" ]; then
  T4_DIR="$RUNTIME_DIR/t4"
  T4_NACOS_URL="http://localhost:18848/nacos"
  T4_API_URL="https://localhost:18443"
  T4_GATEWAY_URL="http://localhost:18080"
  API_URL="$T4_API_URL"
  NACOS_URL="$T4_NACOS_URL"
  COMPOSE_FILE="$T4_DIR/docker-compose.yaml"
fi

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

fail() {
  echo "[$(now)] FAIL: $*" >&2
  collect_logs
  cleanup
  exit 1
}

collect_logs() {
  mkdir -p "$LOG_DIR"
  docker compose -f "$COMPOSE_FILE" logs -t nacos >"$LOG_DIR/nacos.log" 2>&1 || true
  docker compose -f "$COMPOSE_FILE" logs -t apiserver >"$LOG_DIR/apiserver.log" 2>&1 || true
  if [ "$MODE" = "gateway" ]; then
    for svc in initializer precheck prepare controller pilot gateway canary-backend; do
      docker compose -f "$COMPOSE_FILE" logs -t "$svc" >"$LOG_DIR/$svc.log" 2>&1 || true
    done
    gateway_config_dump >"$LOG_DIR/config-dump-final.json" 2>/dev/null || true
  fi
  echo "[$(now)] logs collected under $LOG_DIR (events: $EVENTS_FILE)" >&2
}

cleanup() {
  if [ -n "$WATCHER_PID" ]; then
    touch "$STOP_WATCH_FILE" 2>/dev/null || true
    kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
    WATCHER_PID=""
  fi
  rm -f "$STOP_WATCH_FILE"
  if [ "$KEEP" != "true" ]; then
    docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
  fi
}

# --- Nacos HTTP API -------------------------------------------------------
#
# The v2 config API is used because the v1 write endpoint ignores
# namespaceId on Nacos 3.x compat mode and would silently write into the
# default namespace.

nacos_config_url() { # $1 group, $2 dataId
  echo "$NACOS_URL/v2/cs/config?dataId=$2&group=$1&namespaceId=$NAMESPACE"
}

nacos_publish() { # $1 group, $2 dataId, $3 content
  local body code
  body=$(curl -s -w $'\n%{http_code}' -X POST "$NACOS_URL/v2/cs/config" \
    --data-urlencode "dataId=$2" \
    --data-urlencode "group=$1" \
    --data-urlencode "namespaceId=$NAMESPACE" \
    --data-urlencode "content=$3")
  code=$(tail -n1 <<<"$body")
  [ "$code" = "200" ] || fail "publishing $1/$2 through the Nacos API failed with HTTP $code"
  grep -q '"code":0' <<<"$body" || fail "publishing $1/$2 rejected by Nacos: $body"
}

nacos_delete() { # $1 group, $2 dataId
  local body code
  body=$(curl -s -w $'\n%{http_code}' -X DELETE "$(nacos_config_url "$1" "$2")")
  code=$(tail -n1 <<<"$body")
  [ "$code" = "200" ] || fail "deleting $1/$2 through the Nacos API failed with HTTP $code"
  grep -q '"code":0' <<<"$body" || fail "deleting $1/$2 rejected by Nacos: $body"
}

nacos_config_exists() { # $1 group, $2 dataId
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$(nacos_config_url "$1" "$2")")
  [ "$code" = "200" ]
}

nacos_get_content() { # $1 group, $2 dataId; prints the raw content
  curl -s "$(nacos_config_url "$1" "$2")" | sed 's/^{"code":0,"message":"success","data"://; s/}$//' || true
}

# --- API server REST surface ---------------------------------------------

api_ingress_url() { # $1 ingress name
  echo "$API_URL/apis/networking.k8s.io/v1/namespaces/$NAMESPACE/ingresses/$1"
}

api_ingress_code() { # $1 ingress name
  curl -sk -o /dev/null -w "%{http_code}" "$(api_ingress_url "$1")" || echo 000
}

api_publish_ingress() { # $1 ingress manifest (YAML)
  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" -X POST \
    "$API_URL/apis/networking.k8s.io/v1/namespaces/$NAMESPACE/ingresses" \
    -H "Content-Type: application/yaml" --data-binary "$1")
  [ "$code" = "201" ] || fail "publishing the ingress through the API server failed with HTTP $code"
}

api_delete_ingress() { # $1 ingress name
  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" -X DELETE "$(api_ingress_url "$1")")
  [ "$code" = "200" ] || fail "deleting the ingress through the API server failed with HTTP $code"
}

gateway_config_dump() {
  docker compose -f "$COMPOSE_FILE" exec -T gateway curl -s http://127.0.0.1:15000/config_dump
}

# HTTP probes run inside the gateway container: the Docker Desktop host port
# publishing proved flaky under load, while in-container access to the envoy
# listener is stable and equivalent for black-box assertions.
gateway_http_code() { # $1 path
  docker compose -f "$COMPOSE_FILE" exec -T gateway curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:80$1" || echo 000
}

gateway_http_body() { # $1 path
  docker compose -f "$COMPOSE_FILE" exec -T gateway curl -s "http://127.0.0.1:80$1" || true
}

# --- Bounded waiting ------------------------------------------------------

wait_for_watch_event() { # $1 event type, $2 uid, $3 first line to consider
  local type="$1" uid="$2" firstLine="$3" waited=0
  while [ "$waited" -lt "$WAIT_TIMEOUT_SECS" ]; do
    if tail -n +"$firstLine" "$EVENTS_FILE" 2>/dev/null | grep -q "\"type\":\"$type\".*\"uid\":\"$uid\""; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  fail "timed out after ${WAIT_TIMEOUT_SECS}s waiting for a $type watch event with uid=$uid"
}

wait_for_api_status() { # $1 ingress name, $2 expected HTTP code
  local name="$1" expected="$2" waited=0 code
  while [ "$waited" -lt "$WAIT_TIMEOUT_SECS" ]; do
    code=$(api_ingress_code "$name")
    [ "$code" = "$expected" ] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  fail "timed out after ${WAIT_TIMEOUT_SECS}s waiting for GET ingresses/$name to return $expected (last code: $code)"
}

wait_for_gateway_status() { # $1 path, $2 expected HTTP code
  local path="$1" expected="$2" waited=0 code
  while [ "$waited" -lt "$WAIT_TIMEOUT_SECS" ]; do
    code=$(gateway_http_code "$path")
    [ "$code" = "$expected" ] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  fail "timed out after ${WAIT_TIMEOUT_SECS}s waiting for GET $path at the gateway to return $expected (last code: $code)"
}

wait_for_gateway_route_gone() { # $1 marker (must not appear in config_dump)
  local marker="$1" waited=0 dump
  while [ "$waited" -lt "$WAIT_TIMEOUT_SECS" ]; do
    dump=$(gateway_config_dump 2>/dev/null || echo "")
    if ! grep -qF "$marker" <<<"$dump"; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  fail "timed out after ${WAIT_TIMEOUT_SECS}s waiting for the route to disappear from the gateway config_dump"
}

# --- T3: chain scenarios --------------------------------------------------

ingress_content() { # $1 uid
  printf '{"kind":"Ingress","apiVersion":"networking.k8s.io/v1","metadata":{"name":"%s","namespace":"%s","uid":"%s","labels":{"app":"issue-4538"}},"spec":{"rules":[{"host":"canary.example.com"}]}}' \
    "$INGRESS_NAME" "$NAMESPACE" "$1"
}

event_mark() {
  # Next line number of the events file; earlier events are never considered.
  echo $(( $(wc -l <"$EVENTS_FILE") + 1 ))
}

scenario_clean_delete() {
  echo "[$(now)] scenario 1: clean delete"
  local uid="uid-4538-clean"
  local mark
  mark=$(event_mark)

  nacos_publish "$GROUP" "$DATA_ID" "$(ingress_content "$uid")"
  wait_for_watch_event ADDED "$uid" "$mark"
  wait_for_api_status "$INGRESS_NAME" 200

  nacos_delete "$GROUP" "$DATA_ID"
  wait_for_watch_event DELETED "$uid" "$mark"
  wait_for_api_status "$INGRESS_NAME" 404
  echo "[$(now)] scenario 1 passed: watch DELETED($uid) observed, API GET returns 404"
}

scenario_invalid_overwrite_delete() {
  echo "[$(now)] scenario 2: invalid overwrite (\"x\") then delete"
  local uid="uid-4538-invalid"
  local mark
  mark=$(event_mark)

  nacos_publish "$GROUP" "$DATA_ID" "$(ingress_content "$uid")"
  wait_for_watch_event ADDED "$uid" "$mark"
  wait_for_api_status "$INGRESS_NAME" 200

  # The issue reporter overwrote the Ingress content with a single character
  # before the final delete. Reproduce that through the Nacos API and make
  # sure at least one full refresh cycle has observed the invalid content.
  nacos_publish "$GROUP" "$DATA_ID" "x"
  local content
  content=$(nacos_get_content "$GROUP" "$DATA_ID")
  [ "$content" = '"x"' ] || fail "Nacos did not return the overwritten content (got: $content)"
  sleep $((REFRESH_INTERVAL_SECS + 2))

  nacos_delete "$GROUP" "$DATA_ID"
  wait_for_watch_event DELETED "$uid" "$mark"
  wait_for_api_status "$INGRESS_NAME" 404
  echo "[$(now)] scenario 2 passed: watch DELETED($uid) observed after invalid overwrite, API GET returns 404"
}

scenario_valid_update_delete() {
  echo "[$(now)] scenario 3: valid update then delete"
  local uidA="uid-4538-mod-a" uidB="uid-4538-mod-b"
  local mark
  mark=$(event_mark)

  nacos_publish "$GROUP" "$DATA_ID" "$(ingress_content "$uidA")"
  wait_for_watch_event ADDED "$uidA" "$mark"

  local contentB
  contentB=$(ingress_content "$uidB" | sed 's/"app":"issue-4538"/"app":"issue-4538-v2"/')
  nacos_publish "$GROUP" "$DATA_ID" "$contentB"
  wait_for_watch_event MODIFIED "$uidB" "$mark"

  nacos_delete "$GROUP" "$DATA_ID"
  wait_for_watch_event DELETED "$uidB" "$mark"
  if tail -n +"$mark" "$EVENTS_FILE" | grep -q "\"type\":\"DELETED\".*\"uid\":\"$uidA\""; then
    fail "the deletion was reported with the stale object uidA instead of uidB"
  fi
  wait_for_api_status "$INGRESS_NAME" 404
  echo "[$(now)] scenario 3 passed: watch MODIFIED($uidB) then DELETED($uidB), API GET returns 404"
}

# --- Environment bootstrap (chain mode) -----------------------------------

gen_certs() {
  [ -f "$CERTS_DIR/ca.crt" ] && [ -f "$CERTS_DIR/server.crt" ] && [ -f "$CERTS_DIR/server.key" ] && return 0
  echo "[$(now)] generating throwaway API server certificates"
  mkdir -p "$CERTS_DIR"
  local tmp
  tmp=$(mktemp -d)
  # MSYS2_ARG_CONV_EXCL stops Git Bash from rewriting the -subj value into a
  # Windows path while keeping normal path conversion for the file arguments;
  # the variable is simply unused on Linux.
  MSYS2_ARG_CONV_EXCL='/CN=' openssl req -nodes -new -x509 -days 30 -keyout "$CERTS_DIR/ca.key" -out "$CERTS_DIR/ca.crt" \
    -subj "/CN=nacos-delete-test-ca" >/dev/null
  MSYS2_ARG_CONV_EXCL='/CN=' openssl req -out "$tmp/server.csr" -new -newkey rsa:2048 -nodes -keyout "$CERTS_DIR/server.key" \
    -subj "/CN=higress-apiserver" >/dev/null
  printf "subjectAltName=DNS:localhost,IP:127.0.0.1\n" >"$tmp/san.ext"
  MSYS2_ARG_CONV_EXCL='/CN=' openssl x509 -req -days 30 -in "$tmp/server.csr" -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" \
    -set_serial 01 -sha256 -extfile "$tmp/san.ext" -out "$CERTS_DIR/server.crt" >/dev/null
  rm -rf "$tmp"
}

wait_for_nacos() {
  echo "[$(now)] waiting for the Nacos API"
  local waited=0 code
  while [ "$waited" -lt "$WAIT_TIMEOUT_SECS" ]; do
    # Any well-formed config API answer (404 for a missing config counts)
    # proves the server and its compatibility API are up.
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      "$(nacos_config_url "$GROUP" "readiness-probe")" || echo 000)
    case "$code" in
    200 | 404) return 0 ;;
    esac
    sleep 1
    waited=$((waited + 1))
  done
  fail "Nacos API did not become ready within ${WAIT_TIMEOUT_SECS}s (last code: $code)"
}

ensure_namespace() {
  local list code
  list=$(curl -s "$NACOS_URL/v3/admin/core/namespace/list" || true)
  if grep -q "\"namespace\":\"$NAMESPACE\"" <<<"$list"; then
    echo "[$(now)] Nacos namespace $NAMESPACE already exists"
    return
  fi
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$NACOS_URL/v3/admin/core/namespace" \
    --data-urlencode "namespaceId=$NAMESPACE" \
    --data-urlencode "namespaceName=$NAMESPACE")
  [ "$code" = "200" ] || fail "creating Nacos namespace $NAMESPACE failed with HTTP $code"
  echo "[$(now)] Nacos namespace $NAMESPACE created"
}

ensure_clean_state() {
  if nacos_config_exists "$GROUP" "$DATA_ID"; then
    echo "[$(now)] removing leftover $GROUP/$DATA_ID from a previous run"
    nacos_delete "$GROUP" "$DATA_ID"
    sleep 2
  fi
}

wait_for_apiserver() {
  echo "[$(now)] waiting for the API server"
  local waited=0
  while [ "$waited" -lt "$WAIT_TIMEOUT_SECS" ]; do
    if [ "$(curl -sk -o /dev/null -w "%{http_code}" "$API_URL/readyz")" = "200" ]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  fail "API server did not become ready within ${WAIT_TIMEOUT_SECS}s"
}

start_watcher() {
  echo "[$(now)] consuming the Kubernetes watch stream"
  : >"$EVENTS_FILE"
  (
    while true; do
      [ -f "$STOP_WATCH_FILE" ] && break
      curl -sk -N --max-time 330 \
        "$API_URL/apis/networking.k8s.io/v1/namespaces/$NAMESPACE/ingresses?watch=true&timeoutSeconds=300" \
        >>"$EVENTS_FILE" 2>/dev/null || true
    done
  ) &
  WATCHER_PID=$!
  # Give the initial snapshot a moment to flush so scenario markers are sound.
  sleep 2
}

# --- T4: gateway acceptance ----------------------------------------------

T4_GATEWAY_HTTP_PORT=18080
T4_GATEWAY_IMAGE="higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/gateway:2.2.3@sha256:cf1fa0e100e79890b1de15c74f41a21fabba8f854b9d004d8f5b8ccb48a95c5d"
T4_PILOT_IMAGE="higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/pilot:2.2.3@sha256:6e6520eff97e1404bbbfa116d913bdb1a764e484f7a6a1320ec5e62dd13b24fc"
T4_CONTROLLER_IMAGE="higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/higress:2.2.3@sha256:11fb1244d35615210faaa6bda54cd187e6a445e09892da4cc2619896c34b0e11"

generate_gateway_stack() {
  echo "[$(now)] generating the standalone gateway stack under $T4_DIR"
  # Drop any leftovers of a previous (possibly killed) run before the old
  # compose file is replaced.
  timeout 120 docker compose -p t4 down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$T4_DIR"
  mkdir -p "$T4_DIR/canary" "$T4_DIR/volumes"
  cp -r "$REPO_COMPOSE_DIR/scripts" "$T4_DIR/scripts"
  cp -r "$REPO_COMPOSE_DIR/env" "$T4_DIR/env"
  # The working tree may carry CRLF line endings (Windows checkout); the
  # runner containers execute these scripts with bash, which cannot.
  find "$T4_DIR/scripts" "$T4_DIR/env" -type f -exec sed -i 's/\r$//' {} +

  cat >"$T4_DIR/canary/default.conf" <<'EOF'
server {
  listen 8080;
  location / {
    default_type text/plain;
    return 200 'issue-4538-ok';
  }
}
EOF

  # Task-specific slim copy of the repository compose stack: same
  # initializer/precheck/prepare flow, versions pinned to the 2.2.3
  # combination from the issue report, API server swapped for the variant
  # under test, plus a dedicated canary backend. Observability services and
  # the console are not needed for this acceptance.
  cat >"$T4_DIR/docker-compose.yaml" <<EOF
version: '3.9'

networks:
  higress-net:
    external: false

services:
  nacos:
    hostname: higress-nacos
    image: higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/nacos-server:v3.0.1
    env_file:
      - ./env/nacos.env
    networks:
      higress-net:
        aliases:
          - nacos.svc
    healthcheck:
      test: [ "CMD", "curl", "-f", "http://127.0.0.1:8848/nacos" ]
      interval: 1s
      timeout: 3s
      retries: 60
    volumes:
      - ./volumes/nacos:/home/nacos/data
    ports:
      - "18848:8848/tcp"

  initializer:
    hostname: higress-initializer
    image: higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/runner:0.0.3
    command:
      - ./init.sh
    env_file:
      - ./.env
    networks:
      - higress-net
    volumes:
      - ./volumes:/mnt/volumes
      - ./scripts:/workspace
      - ./volumes/dummy:/opt/data/:rw

  precheck:
    hostname: higress-precheck
    image: higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/runner:0.0.3
    command:
      - ./precheck.sh
    env_file:
      - ./.env
    networks:
      - higress-net
    restart: on-failure
    volumes:
      - ./volumes:/mnt/volumes:rw
      - ./scripts:/workspace:ro
      - ./volumes/dummy:/opt/data/:ro

  apiserver:
    hostname: higress-apiserver
    image: higress-4538/apiserver:$VARIANT
    command:
      - --secure-port
      - "8443"
      - --client-ca-file
      - /etc/api/ca.crt
      - --tls-cert-file
      - /etc/api/server.crt
      - --tls-private-key-file
      - /etc/api/server.key
      - --storage
      - nacos
      - --file-root-dir
      - /opt/data
      - --nacos-server
      - http://nacos:8848/nacos
      - --nacos-ns-id
      - higress-system
    depends_on:
      precheck:
        condition: service_completed_successfully
    networks:
      higress-net:
        aliases:
          - apiserver.svc
    restart: always
    healthcheck:
      test: [ "CMD", "curl", "-fk", "https://127.0.0.1:8443/readyz" ]
      interval: 1s
      timeout: 3s
      retries: 60
    volumes:
      - ./volumes/api:/etc/api:ro
    ports:
      - "18443:8443/tcp"

  prepare:
    hostname: higress-prepare
    image: higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/runner:0.0.3
    command:
      - ./prepare.sh
    env_file:
      - ./.env
    depends_on:
      apiserver:
        condition: service_healthy
    networks:
      - higress-net
    restart: on-failure
    volumes:
      - ./volumes:/mnt/volumes:rw
      - ./scripts:/workspace:ro
      - ./volumes/dummy:/opt/data/:ro

  canary-backend:
    hostname: canary-backend
    image: nginx:alpine
    networks:
      higress-net:
        aliases:
          - canary-backend.svc
    healthcheck:
      test: [ "CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1" ]
      interval: 2s
      timeout: 3s
      retries: 30
    volumes:
      - ./canary/default.conf:/etc/nginx/conf.d/default.conf:ro

  controller:
    hostname: higress-controller
    image: $T4_CONTROLLER_IMAGE
    command:
      - serve
      - --kubeconfig=/home/higress/.kube/config
      - --gatewaySelectorKey=higress
      - --gatewaySelectorValue=higress-system-higress-gateway
      - --ingressClass=
      - --enableAutomaticHttps=true
      - --automaticHttpsEmail=
    env_file:
      - ./env/controller.env
    depends_on:
      prepare:
        condition: service_completed_successfully
      canary-backend:
        condition: service_healthy
    networks:
      higress-net:
        aliases:
          - controller.svc
    restart: always
    healthcheck:
      test: [ "CMD", "curl", "-f", "http://127.0.0.1:8888/ready" ]
      interval: 1s
      timeout: 3s
      retries: 60
    volumes:
      - ./volumes/kube:/home/higress/.kube:ro
      - ./volumes/controller/log/nacos:/var/log/nacos:rw

  pilot:
    hostname: higress-pilot
    image: $T4_PILOT_IMAGE
    command:
      - discovery
      - --monitoringAddr=:15014
      - --log_output_level=default:info
      - --domain
      - cluster.local
      - --keepaliveMaxServerConnectionAge
      - 30m
      - --caCertFile
      - /etc/cacerts/ca-cert.pem
    depends_on:
      controller:
        condition: service_healthy
    env_file:
      - ./env/pilot.env
    networks:
      higress-net:
        aliases:
          - pilot.svc
    restart: always
    healthcheck:
      test: [ "CMD", "curl", "-fk", "http://127.0.0.1:8080/ready" ]
      interval: 1s
      timeout: 3s
      retries: 60
    volumes:
      - ./volumes/kube:/var/run/secrets/remote:ro
      - ./volumes/pilot/cacerts:/etc/cacerts:ro
      - ./volumes/pilot/config:/etc/istio/config:ro

  gateway:
    hostname: higress-gateway
    image: $T4_GATEWAY_IMAGE
    command:
      - proxy
      - router
      - --concurrency
      - "16"
      - --domain
      - higress-system.svc.cluster.local
      - --proxyLogLevel=warning
      - --proxyComponentLogLevel=misc:error
      - --log_output_level=all:info
      - --serviceCluster=higress-gateway
    env_file:
      - ./env/gateway.env
    depends_on:
      pilot:
        condition: service_healthy
    networks:
      higress-net:
        aliases:
          - gateway.svc
    restart: always
    ports:
      - "$T4_GATEWAY_HTTP_PORT:80/tcp"
    healthcheck:
      test:
        [
          "CMD",
          "curl",
          "-fk",
          "http://127.0.0.1:15021/healthz/ready"
        ]
      interval: 1s
      timeout: 3s
      retries: 60
    volumes:
      - ./volumes/pilot/config:/etc/istio/config:ro
      - ./volumes/gateway/certs:/etc/certs:ro
      - ./volumes/gateway/podinfo:/etc/istio/pod:ro
      - ./volumes/gateway/istio/data:/var/lib/istio/data:rw
      - ./volumes/gateway/log:/var/log/proxy:rw
      - ./volumes/gateway/secrets:/var/run/secrets:rw
      - ./volumes/gateway/proxy:/etc/istio/proxy:rw
EOF

  cat >"$T4_DIR/.env" <<EOF
CONFIG_STORAGE='nacos'
FILE_ROOT_DIR=''
NACOS_SERVER_URL='http://nacos:8848/nacos'
NACOS_NS='higress-system'
NACOS_USERNAME=''
NACOS_PASSWORD=''
NACOS_DATA_ENC_KEY=''
NACOS_SERVER_TAG='v3.0.1'
COMPOSE_PROFILES=''
EOF
}

wait_for_service_healthy() { # $1 service name
  local svc="$1" waited=0 status
  while [ "$waited" -lt 180 ]; do
    status=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}} {{.Health}}' 2>/dev/null \
      | { grep "$svc" || true; } | awk '{print $2}')
    [ "$status" = "healthy" ] && return 0
    sleep 2
    waited=$((waited + 2))
  done
  fail "service $svc did not become healthy within 180s (status: $status)"
}

publish_canary_ingress() { # $1 uid
  local uid="$1"
  api_publish_ingress "apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $INGRESS_NAME
  namespace: $NAMESPACE
  uid: $uid
  annotations:
    higress.io/destination: canary.dns:8080
spec:
  ingressClassName: higress
  rules:
  - http:
      paths:
      - backend:
          resource:
            apiGroup: networking.higress.io
            kind: McpBridge
            name: default
        path: /canary-test
        pathType: Prefix"
}

# A second, independent route that stays for the whole run: it keeps the
# envoy listener alive (with zero routes the gateway drops the :80 listener
# entirely, so a deleted route would answer connection-refused instead of
# 404), and it proves the deletion does not disturb unrelated routes.
publish_keepalive_ingress() { # $1 uid
  local uid="$1"
  api_publish_ingress "apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keepalive-test
  namespace: $NAMESPACE
  uid: $uid
  annotations:
    higress.io/destination: canary.dns:8080
spec:
  ingressClassName: higress
  rules:
  - http:
      paths:
      - backend:
          resource:
            apiGroup: networking.higress.io
            kind: McpBridge
            name: default
        path: /keepalive-test
        pathType: Prefix"
}

assert_gateway_route_present() {
  wait_for_gateway_status "/canary-test" 200
  local body
  body=$(gateway_http_body "/canary-test")
  [ "$body" = "issue-4538-ok" ] || fail "gateway returned \"$body\" instead of the canary backend answer"
  gateway_config_dump | grep -qF "/canary-test" || fail "the /canary-test route is missing from the gateway config_dump"
}

assert_deletion_propagated() { # $1 dump marker file
  wait_for_api_status "$INGRESS_NAME" 404
  wait_for_gateway_status "/canary-test" 404
  wait_for_gateway_route_gone "/canary-test"
  # The unrelated keepalive route must survive untouched.
  wait_for_gateway_status "/keepalive-test" 200
}

gateway_clean_delete_scenario() {
  echo "[$(now)] gateway scenario: clean delete"
  local uid="uid-4538-gw-clean"
  publish_canary_ingress "$uid"
  wait_for_api_status "$INGRESS_NAME" 200
  assert_gateway_route_present
  gateway_config_dump >"$LOG_DIR/config-dump-before-clean-delete.json"

  api_delete_ingress "$INGRESS_NAME"
  assert_deletion_propagated
  gateway_config_dump >"$LOG_DIR/config-dump-after-clean-delete.json"
  echo "[$(now)] gateway scenario passed: clean delete propagated to the gateway"
}

gateway_invalid_overwrite_scenario() {
  echo "[$(now)] gateway scenario: invalid overwrite (\"x\") then delete"
  local uid="uid-4538-gw-invalid"
  publish_canary_ingress "$uid"
  wait_for_api_status "$INGRESS_NAME" 200
  assert_gateway_route_present

  # Overwrite the raw Ingress content in Nacos directly, bypassing the API
  # server, exactly like the issue reporter did. Make sure at least one full
  # refresh cycle has observed the invalid content before deleting.
  nacos_publish "$GROUP" "$DATA_ID" "x"
  local content
  content=$(nacos_get_content "$GROUP" "$DATA_ID")
  [ "$content" = '"x"' ] || fail "Nacos did not return the overwritten content (got: $content)"
  sleep $((REFRESH_INTERVAL_SECS + 2))

  gateway_config_dump >"$LOG_DIR/config-dump-before-x-delete.json"
  # The fix variant deletes through the API server. The baseline variant
  # cannot: its GET re-decodes the overwritten content, fails, and the DELETE
  # answers 500 - so fall back to deleting through the Nacos API, which is
  # exactly what the issue reporter did from the Nacos console.
  local del_code
  del_code=$(curl -sk -o /dev/null -w "%{http_code}" -X DELETE "$(api_ingress_url "$INGRESS_NAME")")
  if [ "$del_code" != "200" ]; then
    echo "[$(now)] API DELETE returned $del_code (stale content no longer decodes); deleting through the Nacos API instead"
    nacos_delete "$GROUP" "$DATA_ID"
  fi
  assert_deletion_propagated
  gateway_config_dump >"$LOG_DIR/config-dump-after-x-delete.json"
  echo "[$(now)] gateway scenario passed: delete after invalid overwrite propagated to the gateway"
}

gateway_restart_scenario() {
  echo "[$(now)] gateway scenario: gateway restart keeps the route deleted"
  docker compose -f "$COMPOSE_FILE" restart gateway >/dev/null
  wait_for_service_healthy gateway
  wait_for_gateway_status "/canary-test" 404
  gateway_config_dump | grep -q "/canary-test" &&
    fail "the deleted route reappeared in the gateway config_dump after a restart"
  echo "[$(now)] gateway scenario passed: no route resurrection after gateway restart"
}

gateway_recreate_scenario() {
  echo "[$(now)] gateway scenario: recreate under the same name, then delete again"
  local uid="uid-4538-gw-recreate"
  publish_canary_ingress "$uid"
  wait_for_api_status "$INGRESS_NAME" 200
  assert_gateway_route_present

  api_delete_ingress "$INGRESS_NAME"
  assert_deletion_propagated
  echo "[$(now)] gateway scenario passed: recreation works and the second deletion still cleans up"
}

run_gateway_mode() {
  LOG_DIR="$RUNTIME_DIR/t4-logs"
  EVENTS_FILE="$LOG_DIR/api-watch.jsonl"
  gen_certs
  generate_gateway_stack

  echo "[$(now)] starting the 2.2.3 standalone stack (variant: $VARIANT)"
  # Bounded: a crashing on-failure dependency (e.g. precheck) would otherwise
  # block the dependency-aware up forever.
  timeout 600 docker compose -f "$COMPOSE_FILE" up -d || fail "docker compose up failed or timed out"

  wait_for_nacos
  ensure_namespace
  ensure_clean_state

  wait_for_apiserver
  wait_for_service_healthy canary-backend

  # Configure the canary registry on the McpBridge created by prepare.sh.
  local mcpbridge
  mcpbridge=$(curl -sk "$API_URL/apis/networking.higress.io/v1/namespaces/$NAMESPACE/mcpbridges/default" \
    -H "Accept: application/yaml" || true)
  [ -n "$mcpbridge" ] || fail "could not read the McpBridge from the API server"
  if grep -q "name: canary" <<<"$mcpbridge"; then
    echo "[$(now)] McpBridge already carries the canary registry"
  else
    local updated
    if grep -q "registries:" <<<"$mcpbridge"; then
      updated=$(sed 's/^  registries:$/  registries:\n  - domain: canary-backend.svc\n    name: canary\n    port: 8080\n    type: dns/' <<<"$mcpbridge")
    else
      updated="$mcpbridge
spec:
  registries:
  - domain: canary-backend.svc
    name: canary
    port: 8080
    type: dns"
    fi
    local code
    code=$(curl -sk -o /dev/null -w "%{http_code}" -X PUT \
      "$API_URL/apis/networking.higress.io/v1/namespaces/$NAMESPACE/mcpbridges/default" \
      -H "Content-Type: application/yaml" --data-binary "$updated")
    [ "$code" = "200" ] || fail "updating the McpBridge failed with HTTP $code"
  fi

  mkdir -p "$LOG_DIR"
  start_watcher

  # The independent route that must survive every canary-test deletion.
  publish_keepalive_ingress "uid-4538-keepalive"
  wait_for_api_status "keepalive-test" 200
  wait_for_gateway_status "/keepalive-test" 200

  gateway_clean_delete_scenario
  gateway_invalid_overwrite_scenario
  gateway_restart_scenario
  gateway_recreate_scenario

  echo "[$(now)] gateway acceptance passed for variant: $VARIANT"
}

# --- Main -----------------------------------------------------------------

trap 'fail "script aborted unexpectedly"' INT TERM

if [ "$MODE" = "gateway" ]; then
  run_gateway_mode
  cleanup
  exit 0
fi

gen_certs

echo "[$(now)] building and starting the isolated stack (project: higress-nacos-delete-4538)"
docker compose -f "$COMPOSE_FILE" up -d --build || fail "docker compose up failed"

wait_for_nacos
ensure_namespace
ensure_clean_state
wait_for_apiserver

mkdir -p "$RUNTIME_DIR"
start_watcher

scenario_clean_delete
scenario_invalid_overwrite_delete
scenario_valid_update_delete

cleanup

echo "[$(now)] all scenarios passed"
exit 0
