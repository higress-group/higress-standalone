#!/bin/bash

AZ_PROXY_VERSION=${AI_PROXY_VERSION:-0.0.1}

if [ -n "$AZURE_OPENAI_SERVICE_URL" ]; then
    AZURE_OPENAI_SERVICE_DOMAIN=$(echo "$AZURE_OPENAI_SERVICE_URL" | awk -F[/:] '{print $4}')
else
    AZURE_OPENAI_SERVICE_DOMAIN="YOUR_RESOURCE_NAME.openai.azure.com"
fi

function initializeWasmPlugins() {
    mkdir -p /data/wasmplugins
    WASM_PLUGIN_CONFIG_FILE="/data/wasmplugins/ai-proxy-$AZ_PROXY_VERSION.yaml"

    if [ -f "$WASM_PLUGIN_CONFIG_FILE" ]; then
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
    higress.io/wasm-plugin-built-in: \"false\"
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
          '*': \"qwen-max\"
          'gpt-3': \"qwen-turbo\"
          'gpt-35-turbo': \"qwen-plus\"
          'gpt-4-turbo': \"qwen-max\"
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
  #url: oci://higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/ai-proxy:$AZ_PROXY_VERSION
  url: oci://docker.io/ch3cho/ai-proxy:$AZ_PROXY_VERSION" > "$WASM_PLUGIN_CONFIG_FILE"
}

function initializeMcpBridge() {
    read -r -d '' AI_REGISTRIES <<EOF
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
EOF
    cd /data/mcpbridges
    awk -v r="$AI_REGISTRIES" '{gsub(/# INSERTION_POINT/,r)}1' default.yaml > default-new.yaml
    mv default-new.yaml default.yaml
    cd -
}

function initializeIngresses() {
    mkdir -p /data/ingresses

    cat <<EOF > /data/ingresses/qwen.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    higress.io/backend-protocol: HTTPS
    higress.io/destination: qwen.dns
    $([ "$DEFAULT_AI_SERVICE" == "qwen" ] && echo -n "disabled." || echo -n "")higress.io/exact-match-header-Authorization: Bearer qwen
    higress.io/ignore-path-case: "false"
    higress.io/proxy-ssl-name: dashscope.aliyuncs.com
    higress.io/proxy-ssl-server-name: "on"
  labels:
    higress.io/resource-definer: higress
  name: qwen
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

    cat <<EOF > /data/ingresses/moonshot.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    higress.io/backend-protocol: HTTPS
    higress.io/destination: moonshot.dns
    $([ "$DEFAULT_AI_SERVICE" == "moonshot" ] && echo -n "disabled." || echo -n "")higress.io/exact-match-header-Authorization: Bearer moonshot
    higress.io/ignore-path-case: "false"
    higress.io/proxy-ssl-name: api.moonshot.cn
    higress.io/proxy-ssl-server-name: "on"
  labels:
    higress.io/resource-definer: higress
  name: moonshot
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

    cat <<EOF > /data/ingresses/azure-openai.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    higress.io/backend-protocol: HTTPS
    higress.io/destination: azure-openai.dns
    $([ "$DEFAULT_AI_SERVICE" == "azure-openai" ] && echo -n "disabled." || echo -n "")higress.io/exact-match-header-Authorization: Bearer azure-openai
    higress.io/ignore-path-case: "false"
    higress.io/proxy-ssl-name: $AZURE_OPENAI_SERVICE_DOMAIN
    higress.io/proxy-ssl-server-name: "on"
  labels:
    higress.io/resource-definer: higress
  name: azure-openai
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

    cat <<EOF > /data/ingresses/openai.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    higress.io/backend-protocol: HTTPS
    higress.io/destination: openai.dns
    $([ "$DEFAULT_AI_SERVICE" == "openai" ] && echo -n "disabled." || echo -n "")higress.io/exact-match-header-Authorization: Bearer openai
    higress.io/ignore-path-case: "false"
    higress.io/proxy-ssl-name: api.openai.com
    higress.io/proxy-ssl-server-name: "on"
  labels:
    higress.io/resource-definer: higress
  name: openai
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