#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/../base.sh

AI_PROXY_VERSION=${AI_PROXY_VERSION:-latest}
MODEL_ROUTER_VERSION=${MODEL_ROUTER_VERSION:-latest}

DEFAULT_AI_SERVICE=${DEFAULT_AI_SERVICE:-}

function initializeWasmPlugins() {
  mkdir -p /data/wasmplugins
  WASM_PLUGIN_CONFIG_FOLDER="/data/wasmplugins"

  DASHSCOPE_API_KEY=${DASHSCOPE_API_KEY:-YOUR_DASHSCOPE_API_KEY}
  DASHSCOPE_API_KEYS=(${DASHSCOPE_API_KEY//,/ })
  DASHSCOPE_API_KEY_CONFIG=""
  if [ "${#DASHSCOPE_API_KEYS[@]}" != "0" ]; then
    if [ -z "$DEFAULT_AI_SERVICE"]; then
      DEFAULT_AI_SERVICE="aliyun"
    fi
    for key in "${DASHSCOPE_API_KEYS[@]}"
    do
      DASHSCOPE_API_KEY_CONFIG="${DASHSCOPE_API_KEY_CONFIG}\n        - \"${key}\""
    done
  fi

  OPENAI_API_KEY=${OPENAI_API_KEY:-YOUR_OPENAI_API_KEY}
  OPENAI_API_KEYS=(${OPENAI_API_KEY//,/ })
  OPENAI_API_KEY_CONFIG=""
  if [ "${#OPENAI_API_KEYS[@]}" != "0" ]; then
    if [ -z "$DEFAULT_AI_SERVICE"]; then
      DEFAULT_AI_SERVICE="openai"
    fi
    for key in "${OPENAI_API_KEYS[@]}"
    do
      OPENAI_API_KEY_CONFIG="${OPENAI_API_KEY_CONFIG}\n        - \"${key}\""
    done
  fi

  MOONSHOT_API_KEY=${MOONSHOT_API_KEY:-YOUR_MOONSHOT_API_KEY}
  MOONSHOT_API_KEYS=(${MOONSHOT_API_KEY//,/ })
  MOONSHOT_API_KEY_CONFIG=""
  if [ "${#MOONSHOT_API_KEYS[@]}" != "0" ]; then
    if [ -z "$DEFAULT_AI_SERVICE"]; then
      DEFAULT_AI_SERVICE="moonshot"
    fi
    for key in "${MOONSHOT_API_KEYS[@]}"
    do
      MOONSHOT_API_KEY_CONFIG="${MOONSHOT_API_KEY_CONFIG}\n        - \"${key}\""
    done
  fi

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
    providers:
    - id: aliyun
      type: qwen
      apiTokens:${DASHSCOPE_API_KEY_CONFIG}
    - id: openai
      type: openai
      apiTokens:${OPENAI_API_KEY_CONFIG}
    - id: moonshot
      type: moonshot
      apiTokens:${MOONSHOT_API_KEY_CONFIG}
  defaultConfigDisable: false
  matchRules:
  - config:
      activeProviderId: aliyun
    configDisable: false
    service:
    - llm-aliyun.internal.dns
  - config:
      activeProviderId: openai
    configDisable: false
    service:
    - llm-openai.internal.dns
  - config:
      activeProviderId: moonshot
    configDisable: false
    service:
    - llm-moonshot.internal.dns
  phase: UNSPECIFIED_PHASE
  priority: 100
  url: oci://higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/ai-proxy:$AI_PROXY_VERSION" > "$WASM_PLUGIN_CONFIG_FOLDER/ai-proxy.internal.yaml"

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
  phase: UNSPECIFIED_PHASE
  priority: 260
  url: oci://higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/model-router:$MODEL_ROUTER_VERSION" > "$WASM_PLUGIN_CONFIG_FOLDER/model-router.internal.yaml"
}

function initializeMcpBridge() {
  read -r -d '' AI_REGISTRIES <<EOF
  # AI_REGISTRIES_START
  - domain: api.moonshot.cn
    name: llm-moonshot.internal
    port: 443
    type: dns
    protocol: https
  - domain: dashscope.aliyuncs.com
    name: llm-aliyun.internal
    port: 443
    type: dns
    protocol: https
  - domain: api.openai.com
    name: llm-openai.internal
    port: 443
    type: dns
    protocol: https
  # AI_REGISTRIES_END
EOF

  cd /data/mcpbridges

  sed -i -z -E 's|# AI_REGISTRIES_START.+# AI_REGISTRIES_END|# AI_REGISTRIES_PLACEHOLDER|' default.yaml
  awk -v r="$AI_REGISTRIES" '{gsub(/# AI_REGISTRIES_PLACEHOLDER/,r)}1' default.yaml > default-new.yaml
  mv default-new.yaml default.yaml
  cd -
}

function initializeIngresses() {
  mkdir -p /data/ingresses

  generateAiIngress "aliyun"
  generateAiIngress "openai"
  generateAiIngress "moonshot"
}

function generateAiIngress() {
  PROVIDER_NAME="$1"

  INGRESS_NAME="ai-route-$PROVIDER_NAME.internal"

  INGRESS_FILE="/data/ingresses/$INGRESS_NAME.yaml"

  cat <<EOF > "$INGRESS_FILE" 
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

function initializeAiRoutes() {
  generateAiRoute "aliyun"
  generateAiRoute "openai"
  generateAiRoute "moonshot"
}

function generateAiRoute() {
  ROUTE_NAME="$1"

  CONFIG_MAP_NAME="ai-route-$ROUTE_NAME.internal"
  CONFIG_MAP_FILE="/data/configmaps/$CONFIG_MAP_NAME.yaml"

  cat <<EOF > "$CONFIG_MAP_FILE" 
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

initializeWasmPlugins
initializeMcpBridge
initializeIngresses
initializeAiRoutes

touch "$CONFIGURED_MARKER"