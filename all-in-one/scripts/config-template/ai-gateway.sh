#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/../base.sh

AI_PROXY_VERSION=${AI_PROXY_VERSION:-latest}
MODEL_ROUTER_VERSION=${MODEL_ROUTER_VERSION:-latest}

function initializeLlmProviderConfigs() {
  local EXTRA_CONFIGS=()

  initializeLlmProviderConfig aliyun qwen DASHSCOPE dashscope.aliyuncs.com
  initializeLlmProviderConfig moonshot moonshot MOONSHOT api.moonshot.cn
  initializeLlmProviderConfig openai openai OPENAI api.openai.com
  initializeLlmProviderConfig ai360 ai360 AI360 api.360.cn
  initializeLlmProviderConfig github github GITHUB models.inference.ai.azure.com
  initializeLlmProviderConfig groq groq GROQ api.groq.com
  initializeLlmProviderConfig baichuan baichuan BAICHUAN api.baichuan-ai.com
  initializeLlmProviderConfig yi yi YI api.lingyiwanwu.com
  initializeLlmProviderConfig deepseek deepseek DEEPSEEK api.deepseek.com
  initializeLlmProviderConfig zhipuai zhipuai ZHIPUAI open.bigmodel.cn
  # initializeLlmProviderConfig baidu baidu BAIDU aip.baidubce.com
  # initializeLlmProviderConfig hunyuan hunyuan HUNYUAN hunyuan.tencentcloudapi.com 443 "https" "" "${EXTRA_CONFIGS[@]}"
  initializeLlmProviderConfig stepfun stepfun STEPFUN api.stepfun.com
  # initializeLlmProviderConfig cloudflare cloudflare CLOUDFLARE api.cloudflare.com 443 "https" "" "${EXTRA_CONFIGS[@]}"
  # initializeLlmProviderConfig spark spark SPARK spark-api-open.xf-yun.com 443 "https" "" "${EXTRA_CONFIGS[@]}"
  initializeLlmProviderConfig gemini gemini GEMINI generativelanguage.googleapis.com
  # initializeLlmProviderConfig deepl deepl DEEPL 443 "https" "" "${EXTRA_CONFIGS[@]}"
  initializeLlmProviderConfig mistral mistral MISTRAL api.mistral.ai
  initializeLlmProviderConfig cohere cohere COHERE api.cohere.com
  initializeLlmProviderConfig doubao doubao DOUBAO ark.cn-beijing.volces.com
  initializeLlmProviderConfig coze coze COZE api.coze.cn

  if [ -z "$AZURE_SERVICE_URL" ]; then
    AZURE_SERVICE_URL="https://YOUR_RESOURCE_NAME.openai.azure.com/openai/deployments/YOUR_DEPLOYMENT_NAME/chat/completions?api-version=2024-06-01"
  fi
  extractHostFromUrl "$AZURE_SERVICE_URL"
  local AZURE_SERVICE_DOMAIN="$HOST"
  EXTRA_CONFIGS=(
    "azureServiceUrl=$AZURE_SERVICE_URL"
  )
  initializeLlmProviderConfig azure azure AZURE "$AZURE_SERVICE_DOMAIN" "443" "https" "" "${EXTRA_CONFIGS[@]}"

  if [ -z "$CLAUDE_VERSION" ]; then
    CLAUDE_VERSION="2023-06-01"
  fi
  EXTRA_CONFIGS=(
    "claudeVersion=\"$CLAUDE_VERSION\""
  )
  initializeLlmProviderConfig claude claude CLAUDE api.anthropic.com "443" "https" "" "${EXTRA_CONFIGS[@]}"

  if [ -z "$OLLAMA_SERVER_HOST" ]; then
    OLLAMA_SERVER_HOST="YOUR_OLLAMA_SERVER_HOST"
  fi
  OLLAMA_SERVER_PORT="${OLLAMA_SERVER_PORT:-11434}"
  EXTRA_CONFIGS=(
    "ollamaServerHost=\"$OLLAMA_SERVER_HOST\""
    "ollamaServerPort=$OLLAMA_SERVER_PORT"
  )
  initializeLlmProviderConfig ollama ollama OLLAMA "$OLLAMA_SERVER_HOST" "$OLLAMA_SERVER_PORT" "http" "" "${EXTRA_CONFIGS[@]}"

  EXTRA_CONFIGS=(
    "minimaxGroupId=\"$MINIMAX_GROUP_ID\""
  )
  initializeLlmProviderConfig minimax minimax MINIMAX api.minimax.chat "443" "https" "" "${EXTRA_CONFIGS[@]}"
}

function initializeLlmProviderConfig() {
  local NAME="$1"
  shift
  local TYPE="$1"
  shift
  local API_KEY_PREFIX="$1"
  shift
  local DOMAIN="$1"
  shift
  local PORT="$1"
  shift
  local PROTOCOL="$1"
  shift
  local DEFAULT_API_KEY="$1"
  shift
  local EXTRA_CONFIGS=("$@")

  appendAiRegistry "$NAME" "$DOMAIN" "$PORT" "$PROTOCOL"
  appendAiProxyConfigs "$NAME" "$TYPE" "$API_KEY_PREFIX" "$DEFAULT_API_KEY" "${EXTRA_CONFIGS[@]}"
  generateAiIngress "$NAME"
  generateAiRoute "$NAME"
}

function initializeSharedConfigs() {
  initializeWasmPlugins
  initializeMcpBridge
}

function initializeWasmPlugins() {
  local WASM_PLUGIN_CONFIG_FOLDER="/data/wasmplugins"

  mkdir -p "${WASM_PLUGIN_CONFIG_FOLDER}"

  echo -e "\
apiVersion: extensions.higress.io/v1alpha1
kind: WasmPlugin
metadata:
  annotations:
    higress.io/wasm-plugin-title: AI Proxy
  labels:
    higress.io/resource-definer: higress
    higress.io/wasm-plugin-built-in: \"true\"
    higress.io/wasm-plugin-category: ai
    higress.io/wasm-plugin-name: ai-proxy
    higress.io/wasm-plugin-version: 1.0.0
  name: ai-proxy.internal
  namespace: higress-system
  resourceVersion: \"1\"
spec:
  defaultConfig:
    providers:${AI_PROXY_PROVIDERS}
  defaultConfigDisable: false
  matchRules:${AI_PROXY_MATCH_RULES}
  failStrategy: FAIL_OPEN
  phase: UNSPECIFIED_PHASE
  priority: 100
  url: oci://higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/ai-proxy:$AI_PROXY_VERSION" >"$WASM_PLUGIN_CONFIG_FOLDER/ai-proxy.internal.yaml"

  echo -e "\
apiVersion: extensions.higress.io/v1alpha1
kind: WasmPlugin
metadata:
  annotations:
    higress.io/wasm-plugin-title: AI Model Router
  labels:
    higress.io/resource-definer: higress
    higress.io/wasm-plugin-built-in: \"true\"
    higress.io/wasm-plugin-category: ai
    higress.io/wasm-plugin-name: model-router
    higress.io/wasm-plugin-version: 1.0.0
  name: model-router.internal
  namespace: higress-system
  resourceVersion: \"1\"
spec:
  defaultConfig:
    enable: true
    add_header_key: x-higress-llm-provider
  defaultConfigDisable: false
  failStrategy: FAIL_OPEN
  phase: UNSPECIFIED_PHASE
  priority: 260
  url: oci://higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/model-router:$MODEL_ROUTER_VERSION" >"$WASM_PLUGIN_CONFIG_FOLDER/model-router.internal.yaml"
}

function appendAiProxyConfigs() {
  local PROVIDER_ID="$1"
  shift
  local PROVIDER_TYPE="$1"
  shift
  local TOKEN_KEY_PREFIX="$1"
  shift
  local DEFAULT_TOKEN_VALUE="$1"
  shift
  local EXTRA_CONFIGS=("$@")

  if [ -z "$DEFAULT_TOKEN_VALUE" ]; then
    DEFAULT_TOKEN_VALUE="YOUR_${TOKEN_KEY_PREFIX}_API_KEY"
  fi

  local API_TOKENS_KEY="${TOKEN_KEY_PREFIX}_API_KEY"
  local API_TOKENS_RAW=${!API_TOKENS_KEY:-${DEFAULT_TOKEN_VALUE}}
  local API_TOKENS_ARRAY=(${API_TOKENS_RAW//,/ })
  local API_TOKENS_CONFIG=""
  for key in "${API_TOKENS_ARRAY[@]}"; do
    API_TOKENS_CONFIG="${API_TOKENS_CONFIG}
      - \"${key}\""
  done

  AI_PROXY_PROVIDERS="$AI_PROXY_PROVIDERS
    - id: ${PROVIDER_ID}
      type: ${PROVIDER_TYPE}
      apiTokens:${API_TOKENS_CONFIG}"

  AI_PROXY_MATCH_RULES="$AI_PROXY_MATCH_RULES
  - service:
    - $LAST_SERVICE_NAME
    configDisable: false
    config:
      activeProviderId: ${PROVIDER_ID}"

  if [ -n "$EXTRA_CONFIGS" ]; then
    for config in "${EXTRA_CONFIGS[@]}"; do
      KEY=${config%%=*}
      VALUE=${config#*=}
      AI_PROXY_PROVIDERS="${AI_PROXY_PROVIDERS}
      $KEY: $VALUE"
    done
  fi
}

function initializeMcpBridge() {
  mkdir -p /data/mcpbridges
  cd /data/mcpbridges

  sed -i -z -E 's|# AI_REGISTRIES_START.+# AI_REGISTRIES_END|# AI_REGISTRIES_PLACEHOLDER|' default.yaml
  awk -v r="# AI_REGISTRIES_START${AI_REGISTRIES}
  # AI_REGISTRIES_END" '{gsub(/# AI_REGISTRIES_PLACEHOLDER/,r)}1' default.yaml >default-new.yaml
  mv default-new.yaml default.yaml
  cd -
}

function appendAiRegistry() {
  local PROVIDER_NAME="$1"
  local DOMAIN="$2"
  local PORT="$3"
  local PROTOCOL="$4"

  if [ -z "$PORT"]; then
    PORT="443"
  fi
  if [ -z "$PROTOCOL"]; then
    PROTOCOL="https"
  fi

  local TYPE="dns"
  if [[ "$DOMAIN" =~ (25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)){3} ]]; then
    TYPE="static"
  fi

  if [ "$TYPE" == "static" ]; then
    DOMAIN="$DOMAIN:$PORT"
    PORT="80"
  fi

  AI_REGISTRIES="${AI_REGISTRIES}
  - name: llm-$PROVIDER_NAME.internal
    type: $TYPE
    protocol: $PROTOCOL
    domain: $DOMAIN
    port: $PORT"

  LAST_SERVICE_NAME="llm-${PROVIDER_NAME}.internal.${TYPE}"
  LAST_SERVICE_PORT="$PORT"
}

function generateAiIngress() {
  local PROVIDER_NAME="$1"

  local INGRESS_NAME="ai-route-$PROVIDER_NAME.internal"
  local INGRESS_FILE="/data/ingresses/$INGRESS_NAME.yaml"

  mkdir -p /data/ingresses

  cat <<EOF >"$INGRESS_FILE"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    higress.io/destination: $LAST_SERVICE_NAME:$LAST_SERVICE_PORT
    higress.io/ignore-path-case: "false"
    higress.io/exact-match-header-x-higress-llm-provider: $PROVIDER_NAME
  labels:
    higress.io/resource-definer: higress
  name: $INGRESS_NAME
  namespace: higress-system
  resourceVersion: "1"
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
        path: /
        pathType: Prefix
EOF
}

function generateAiRoute() {
  local ROUTE_NAME="$1"

  local CONFIG_MAP_NAME="ai-route-$ROUTE_NAME.internal"
  local CONFIG_MAP_FILE="/data/configmaps/$CONFIG_MAP_NAME.yaml"

  mkdir -p /data/configmaps

  cat <<EOF >"$CONFIG_MAP_FILE"
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    higress.io/config-map-type: ai-route
    higress.io/resource-definer: higress
  name: $CONFIG_MAP_NAME
  namespace: higress-system
  resourceVersion: "1"
data:
  data: |
    {
      "name": "$ROUTE_NAME",
      "upstreams": [
        {
          "provider": "$ROUTE_NAME"
        }
      ],
      "modelPredicate": {
        "enabled": true,
        "prefix": "$ROUTE_NAME"
      },
      "version": "1"
    }
EOF
}

extractHostFromUrl() {
  local url="$1"
  local regex='https?://(([a-zA-Z0-9_-]+)(\.[a-zA-Z0-9._-]+))'
  HOST=""
  if [[ "$url" =~ $regex ]]; then
    HOST="${BASH_REMATCH[1]}"
  fi
}

mkdir -p /data

CONFIGURED_MARKER="/data/.ai-gateway-configured"

if [ -f "$CONFIGURED_MARKER" ]; then
  echo "AI Gateway has been configured already."
  exit 0
fi

initializeLlmProviderConfigs
initializeSharedConfigs

touch "$CONFIGURED_MARKER"
