#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/../base.sh

AI_PROXY_VERSION=${AI_PROXY_VERSION:-latest}
MODEL_ROUTER_VERSION=${MODEL_ROUTER_VERSION:-latest}

function initializeLlmProviderConfigs() {
  # Aliyun
  appendAiRegistry aliyun dashscope.aliyuncs.com
  appendAiProxyConfigs aliyun qwen DASHSCOPE
  generateAiIngress aliyun
  generateAiRoute aliyun

  # Moonshot
  appendAiRegistry moonshot api.moonshot.cn
  appendAiProxyConfigs moonshot moonshot MOONSHOT
  generateAiIngress moonshot
  generateAiRoute moonshot

  # OpenAI
  appendAiRegistry openai api.openai.com
  appendAiProxyConfigs openai openai OPENAI
  generateAiIngress openai
  generateAiRoute openai
}

function initializeSharedConfigs() {
  initializeWasmPlugins
  initializeMcpBridge
}

function initializeWasmPlugins() {
  WASM_PLUGIN_CONFIG_FOLDER="/data/wasmplugins"

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
  PROVIDER_ID="$1"
  PROVIDER_TYPE="$2"
  TOKEN_KEY_PREFIX="$3"
  DEFAULT_TOKEN_VALUE="${4-YOUR_$3_API_KEY}"

  API_TOKENS_KEY="${TOKEN_KEY_PREFIX}_API_KEY"
  API_TOKENS_RAW=${!API_TOKENS_KEY:-${DEFAULT_TOKEN_VALUE}}
  API_TOKENS_ARRAY=(${API_TOKENS_RAW//,/ })
  API_TOKENS_CONFIG=""
  for key in "${API_TOKENS_ARRAY[@]}"; do
    API_TOKENS_CONFIG="${API_TOKENS_CONFIG}
      - \"${key}\""
  done

  AI_PROXY_PROVIDERS="$AI_PROXY_PROVIDERS
    - id: ${PROVIDER_ID}
      type: ${PROVIDER_TYPE}
      apiTokens:${API_TOKENS_CONFIG}"

  AI_PROXY_MATCH_RULES="$AI_PROXY_MATCH_RULES
  - config:
      activeProviderId: ${PROVIDER_ID}
    configDisable: false
    service:
    - llm-${PROVIDER_ID}.internal.dns"
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
  PROVIDER_NAME="$1"
  DOMAIN="$2"
  PORT="${3-443}"
  PROTOCOL="${4-https}"

  AI_REGISTRIES="${AI_REGISTRIES}  
  - name: llm-$PROVIDER_NAME.internal
    type: dns
    protocol: $PROTOCOL
    domain: $DOMAIN
    port: $PORT"
}

function generateAiIngress() {
  PROVIDER_NAME="$1"

  INGRESS_NAME="ai-route-$PROVIDER_NAME.internal"
  INGRESS_FILE="/data/ingresses/$INGRESS_NAME.yaml"

  mkdir -p /data/ingresses

  cat <<EOF >"$INGRESS_FILE"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    higress.io/destination: llm-$PROVIDER_NAME.internal.dns:443
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
  ROUTE_NAME="$1"

  CONFIG_MAP_NAME="ai-route-$ROUTE_NAME.internal"
  CONFIG_MAP_FILE="/data/configmaps/$CONFIG_MAP_NAME.yaml"

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

mkdir -p /data

CONFIGURED_MARKER="/data/.ai-gateway-configured"

if [ -f "$CONFIGURED_MARKER" ]; then
  echo "AI Gateway has been configured already."
  exit 0
fi

initializeLlmProviderConfigs
initializeSharedConfigs

touch "$CONFIGURED_MARKER"
