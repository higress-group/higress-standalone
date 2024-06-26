#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/../base.sh

AZ_PROXY_VERSION=${AI_PROXY_VERSION:-1.0.0}

if [ -n "$AZURE_OPENAI_SERVICE_URL" ]; then
  AZURE_OPENAI_SERVICE_DOMAIN=$(echo "$AZURE_OPENAI_SERVICE_URL" | awk -F[/:] '{print $4}')
else
  AZURE_OPENAI_SERVICE_DOMAIN="YOUR_RESOURCE_NAME.openai.azure.com"
fi

function initializeWasmPlugins() {
  mkdir -p /data/wasmplugins
  WASM_PLUGIN_CONFIG_FILE="/data/wasmplugins/ai-proxy-$AZ_PROXY_VERSION.yaml"

  if [ "$CONSOLE_USED" == 'true' -a -f "$WASM_PLUGIN_CONFIG_FILE" ]; then
    return
  fi

  DASHSCOPE_API_KEY=${DASHSCOPE_API_KEY:-YOUR_DASHSCOPE_API_KEY}
  DASHSCOPE_API_KEYS=(${DASHSCOPE_API_KEY//,/ })
  DASHSCOPE_API_KEY_CONFIG=""
  for key in "${DASHSCOPE_API_KEYS[@]}"
  do
    DASHSCOPE_API_KEY_CONFIG="${DASHSCOPE_API_KEY_CONFIG}\n        - \"${key}\""
  done

  AZURE_OPENAI_API_KEY=${AZURE_OPENAI_API_KEY:-YOUR_AZURE_OPENAI_API_KEY}
  AZURE_OPENAI_API_KEYS=(${AZURE_OPENAI_API_KEY//,/ })
  AZURE_OPENAI_API_KEY_CONFIG=""
  for key in "${AZURE_OPENAI_API_KEYS[@]}"
  do
    AZURE_OPENAI_API_KEY_CONFIG="${AZURE_OPENAI_API_KEY_CONFIG}\n        - \"${key}\""
  done

  OPENAI_API_KEY=${OPENAI_API_KEY:-YOUR_OPENAI_API_KEY}
  OPENAI_API_KEYS=(${OPENAI_API_KEY//,/ })
  OPENAI_API_KEY_CONFIG=""
  for key in "${OPENAI_API_KEYS[@]}"
  do
    OPENAI_API_KEY_CONFIG="${OPENAI_API_KEY_CONFIG}\n        - \"${key}\""
  done

  MOONSHOT_API_KEY=${MOONSHOT_API_KEY:-YOUR_MOONSHOT_API_KEY}
  MOONSHOT_API_KEYS=(${MOONSHOT_API_KEY//,/ })
  MOONSHOT_API_KEY_CONFIG=""
  for key in "${MOONSHOT_API_KEYS[@]}"
  do
    MOONSHOT_API_KEY_CONFIG="${MOONSHOT_API_KEY_CONFIG}\n        - \"${key}\""
  done

  echo -e "\
apiVersion: extensions.higress.io/v1alpha1
kind: WasmPlugin
metadata:
  annotations:
    higress.io/wasm-plugin-title: AI Proxy
  labels:
    higress.io/resource-definer: higress
    higress.io/wasm-plugin-built-in: \"true\"
    higress.io/wasm-plugin-category: custom
    higress.io/wasm-plugin-name: ai-proxy
    higress.io/wasm-plugin-version: $AZ_PROXY_VERSION
  name: ai-proxy-$AZ_PROXY_VERSION
  namespace: higress-system
spec:
  defaultConfig: {}
  defaultConfigDisable: true
  matchRules:
  - config:
      provider:
        type: qwen
        apiTokens:${DASHSCOPE_API_KEY_CONFIG}
        modelMapping:
          '*': \"qwen-plus\"
          'gpt-3.5-turbo': \"qwen-long\",
          'gpt-3.5-turbo-0125': \"qwen-long\",
          'gpt-3.5-turbo-1106': \"qwen-long\",
          'gpt-3.5-turbo-0613': \"qwen-long\",
          'gpt-3.5-turbo-16k-0613': \"qwen-long\",
          'gpt-3.5-turbo-0301': \"qwen-long\",
          'gpt-3.5-turbo-instruct': \"qwen-long\",
          'gpt-4': \"qwen-max\"
          'gpt-4-32k': \"qwen-max\"
          'gpt-4-0125-preview': \"qwen-turbo\"
          'gpt-4-1106-preview': \"qwen-turbo\"
          'gpt-4-vision-preview': \"qwen-turbo\"
          'gpt-4-turbo': \"qwen-turbo\"
          'gpt-4o': \"qwen-plus\"
          'gpt-4o-2024-05-13': \"qwen-plus\"
    configDisable: false
    ingress:
    - qwen
  - config:
      provider:
        type: azure
        apiTokens:${AZURE_OPENAI_API_KEY_CONFIG}
        azureServiceUrl: "${AZURE_OPENAI_SERVICE_URL:-https://YOUR_RESOURCE_NAME.openai.azure.com/openai/deployments/YOUR_DEPLOYMENT_NAME/chat/completions?api-version=2024-02-01}"
    configDisable: false
    ingress:
    - azure-openai
  - config:
      provider:
        type: openai
        apiTokens:${OPENAI_API_KEY_CONFIG}
    configDisable: false
    ingress:
    - openai
  - config:
      provider:
        type: moonshot
        apiTokens:${MOONSHOT_API_KEY_CONFIG}
        modelMapping:
          '*': \"moonshot-v1-128k\"
          'gpt-3': \"moonshot-v1-8k\"
          'gpt-35-turbo': \"moonshot-v1-32k\"
          'gpt-4-turbo': \"moonshot-v1-128k\"
    configDisable: false
    ingress:
    - moonshot
  phase: UNSPECIFIED_PHASE
  priority: \"100\"
  url: oci://higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/ai-proxy:$AZ_PROXY_VERSION" > "$WASM_PLUGIN_CONFIG_FILE"
}

function initializeMcpBridge() {
  read -r -d '' AI_REGISTRIES <<EOF
  # AI_REGISTRIES_START
  - domain: api.moonshot.cn
    name: moonshot
    port: 443
    type: dns
  - domain: $AZURE_OPENAI_SERVICE_DOMAIN
    name: azure-openai
    port: 443
    type: dns
  - domain: dashscope.aliyuncs.com
    name: qwen
    port: 443
    type: dns
  - domain: api.openai.com
    name: openai
    port: 443
    type: dns
  # AI_REGISTRIES_END
EOF

  cd /data/mcpbridges

  if [ "$CONSOLE_USED" == 'true' -a -f "./default.yaml" ]; then
    return
  fi

  sed -i -z -E 's|# AI_REGISTRIES_START.+# AI_REGISTRIES_END|# AI_REGISTRIES_PLACEHOLDER|' default.yaml
  awk -v r="$AI_REGISTRIES" '{gsub(/# AI_REGISTRIES_PLACEHOLDER/,r)}1' default.yaml > default-new.yaml
  mv default-new.yaml default.yaml
  cd -
}

function initializeIngresses() {
  mkdir -p /data/ingresses

  generateAiIngress "moonshot" "api.moonshot.cn"
  generateAiIngress "qwen" "dashscope.aliyuncs.com"
  generateAiIngress "azure-openai" "$AZURE_OPENAI_SERVICE_DOMAIN"
  generateAiIngress "openai" "api.openai.com"
}

function generateAiIngress() {
  PROVIDER_NAME="$1"
  SERVICE_DOMAIN="$2"

  INGRESS_FILE="/data/ingresses/$PROVIDER_NAME.yaml"
  if [ "$CONSOLE_USED" == 'true' -a -f "$INGRESS_FILE" ]; then
    return
  fi

  cat <<EOF > "$INGRESS_FILE" 
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    higress.io/backend-protocol: HTTPS
    higress.io/destination: $PROVIDER_NAME.dns
    $([ "$DEFAULT_AI_SERVICE" == "$PROVIDER_NAME" ] && echo -n "disabled." || echo -n "")higress.io/exact-match-header-Authorization: Bearer $PROVIDER_NAME
    higress.io/ignore-path-case: "false"
    higress.io/proxy-ssl-name: $SERVICE_DOMAIN
    higress.io/proxy-ssl-server-name: "on"
  labels:
    higress.io/resource-definer: higress
  name: $PROVIDER_NAME
  namespace: higress-system
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

initializeWasmPlugins
initializeMcpBridge
initializeIngresses
