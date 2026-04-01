#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/../base.sh

AI_PROXY_VERSION=${AI_PROXY_VERSION:-1.0.0}
AI_STATISTICS_VERSION=${AI_STATISTICS_VERSION:-1.0.0}
MODEL_ROUTER_VERSION=${MODEL_ROUTER_VERSION:-1.0.0}

declare -a GENERATED_INGRESSES

# Normalize model pattern to match type and regex value
# Supports:
#   - Wildcard prefix: "qwen-*" -> PRE "qwen-"
#   - Exact name: "qwen3-max" -> PRE "qwen3-max"
#   - Multiple wildcards: "kimi-*,moonshot-*" -> REGULAR "kimi-.*|moonshot-.*"
#   - Multiple exact: "kimi-2.5,moonshot-k1" -> REGULAR "kimi-2.5|moonshot-k1"
#   - Mixed: "qwen-*,gpt-4" -> REGULAR "qwen-.*|gpt-4"
# Returns: "MATCH_TYPE|MATCH_VALUE"
normalizeModelPattern() {
  local pattern="$1"
  local match_type=""
  local match_value=""
  
  # Remove spaces
  pattern="${pattern// /}"
  
  # Empty pattern defaults to match all
  if [ -z "$pattern" ]; then
    echo "REGULAR|.*"
    return
  fi
  
  # Check if contains comma (multiple patterns)
  if [[ "$pattern" == *","* ]]; then
    IFS=',' read -ra parts <<< "$pattern"
    local regex_parts=()
    
    for part in "${parts[@]}"; do
      if [[ "$part" == *"*" ]]; then
        # Has wildcard, convert * to .*
        part="${part//\*/.*}"
      fi
      regex_parts+=("$part")
    done
    
    # Join with |
    match_value=$(IFS='|'; echo "${regex_parts[*]}")
    match_type="REGULAR"
  else
    # Single pattern
    if [[ "$pattern" == *"*" ]]; then
      # Has wildcard
      if [[ "$pattern" == *"-*" ]] && [[ "$pattern" != *".*" ]]; then
        # Simple suffix wildcard like "qwen-*", use PRE for efficiency
        match_type="PRE"
        match_value="${pattern//\*/}"
      else
        # Complex wildcard, use REGULAR
        match_type="REGULAR"
        match_value="${pattern//\*/.*}"
      fi
    else
      # No wildcard, exact match - use PRE for simple prefix/exact match
      match_type="PRE"
      match_value="$pattern"
    fi
  fi
  
  echo "$match_type|$match_value"
}

# Parse EXTRA_CONFIGS from environment variable (comma-separated key=value pairs)
# Usage: parseExtraConfigs "PROVIDER_EXTRA_CONFIGS"
# Sets global EXTRA_CONFIGS array
parseExtraConfigs() {
  local env_var_name="$1"
  local env_value="${!env_var_name}"
  EXTRA_CONFIGS=()
  if [ -n "$env_value" ]; then
    IFS=',' read -ra configs <<< "$env_value"
    EXTRA_CONFIGS=("${configs[@]}")
  fi
}

# Extract a config value from EXTRA_CONFIGS array
# Usage: getExtraConfigValue "keyName" "defaultValue"
getExtraConfigValue() {
  local key="$1"
  local default="$2"
  for config in "${EXTRA_CONFIGS[@]}"; do
    if [[ "$config" == ${key}=* ]]; then
      local value="${config#${key}=}"
      value="${value//\"/}"
      echo "$value"
      return
    fi
  done
  echo "$default"
}

function initializeLlmProviderConfigs() {
  local EXTRA_CONFIGS=()

  # Top commonly used providers (defaults set in get-ai-gateway.sh)
  initializeLlmProviderConfig aliyun qwen DASHSCOPE dashscope.aliyuncs.com "443" "https" "" "$DASHSCOPE_MODELS"
  
  initializeLlmProviderConfig deepseek deepseek DEEPSEEK api.deepseek.com "443" "https" "" "$DEEPSEEK_MODELS"
  
  initializeLlmProviderConfig moonshot moonshot MOONSHOT api.moonshot.cn "443" "https" "" "$MOONSHOT_MODELS"
  
  parseExtraConfigs "ZHIPUAI_EXTRA_CONFIGS"
  local ZHIPUAI_HOST=$(getExtraConfigValue "zhipuDomain" "open.bigmodel.cn")
  initializeLlmProviderConfig zhipuai zhipuai ZHIPUAI "$ZHIPUAI_HOST" "443" "https" "" "$ZHIPUAI_MODELS" "${EXTRA_CONFIGS[@]}"
  
  parseExtraConfigs "MINIMAX_EXTRA_CONFIGS"
  if [ ${#EXTRA_CONFIGS[@]} -eq 0 ] && [ -n "$MINIMAX_GROUP_ID" ]; then
    EXTRA_CONFIGS=("minimaxGroupId=\"$MINIMAX_GROUP_ID\"")
  fi
  initializeLlmProviderConfig minimax minimax MINIMAX api.minimax.chat "443" "https" "" "$MINIMAX_MODELS" "${EXTRA_CONFIGS[@]}"

  # Azure OpenAI
  if [ -z "$OPENAI_API_KEY" ]; then
    parseExtraConfigs "AZURE_EXTRA_CONFIGS"
    local AZURE_SERVICE_URL_VAL=$(getExtraConfigValue "azureServiceUrl" "")
    if [ -z "$AZURE_SERVICE_URL_VAL" ] && [ -n "$AZURE_SERVICE_URL" ]; then
      AZURE_SERVICE_URL_VAL="$AZURE_SERVICE_URL"
      EXTRA_CONFIGS=("azureServiceUrl=$AZURE_SERVICE_URL")
    elif [ -z "$AZURE_SERVICE_URL_VAL" ]; then
      AZURE_SERVICE_URL_VAL="https://YOUR_RESOURCE_NAME.openai.azure.com/openai/deployments/YOUR_DEPLOYMENT_NAME/chat/completions?api-version=2024-06-01"
      EXTRA_CONFIGS=("azureServiceUrl=$AZURE_SERVICE_URL_VAL")
    fi
    extractHostFromUrl "$AZURE_SERVICE_URL_VAL"
    local AZURE_SERVICE_DOMAIN="$HOST"
    initializeLlmProviderConfig azure azure AZURE "$AZURE_SERVICE_DOMAIN" "443" "https" "" "$AZURE_MODELS" "${EXTRA_CONFIGS[@]}"
  fi

  # AWS Bedrock - requires region configuration
  if [ -n "$BEDROCK_CONFIGURED" ]; then
    parseExtraConfigs "BEDROCK_EXTRA_CONFIGS"
    if [ ${#EXTRA_CONFIGS[@]} -eq 0 ]; then
      # Fallback to individual env vars for backward compatibility
      if [ -n "$BEDROCK_REGION" ]; then
        EXTRA_CONFIGS+=("awsRegion=\"$BEDROCK_REGION\"")
      fi
      if [ -n "$BEDROCK_ACCESS_KEY" ] && [ -n "$BEDROCK_SECRET_KEY" ]; then
        EXTRA_CONFIGS+=("awsAccessKey=\"$BEDROCK_ACCESS_KEY\"")
        EXTRA_CONFIGS+=("awsSecretKey=\"$BEDROCK_SECRET_KEY\"")
      fi
    fi
    local BEDROCK_REGION_VAL=$(getExtraConfigValue "awsRegion" "${BEDROCK_REGION:-us-east-1}")
    initializeLlmProviderConfig bedrock bedrock BEDROCK bedrock-runtime.${BEDROCK_REGION_VAL}.amazonaws.com "443" "https" "" "$BEDROCK_MODELS" "${EXTRA_CONFIGS[@]}"
  fi

  # Google Vertex AI - requires project and region configuration
  if [ -n "$VERTEX_CONFIGURED" ]; then
    parseExtraConfigs "VERTEX_EXTRA_CONFIGS"
    if [ ${#EXTRA_CONFIGS[@]} -eq 0 ]; then
      # Fallback to individual env vars for backward compatibility
      if [ -n "$VERTEX_PROJECT_ID" ]; then
        EXTRA_CONFIGS+=("vertexProjectId=\"$VERTEX_PROJECT_ID\"")
      fi
      if [ -n "$VERTEX_REGION" ]; then
        EXTRA_CONFIGS+=("vertexRegion=\"$VERTEX_REGION\"")
      fi
      if [ -n "$VERTEX_AUTH_KEY" ]; then
        EXTRA_CONFIGS+=("vertexAuthKey=\"$VERTEX_AUTH_KEY\"")
      fi
      if [ -n "$VERTEX_AUTH_SERVICE_NAME" ]; then
        EXTRA_CONFIGS+=("vertexAuthServiceName=\"$VERTEX_AUTH_SERVICE_NAME\"")
      fi
    fi
    local VERTEX_REGION_VAL=$(getExtraConfigValue "vertexRegion" "${VERTEX_REGION:-us-central1}")
    initializeLlmProviderConfig vertex vertex VERTEX ${VERTEX_REGION_VAL}-aiplatform.googleapis.com "443" "https" "" "$VERTEX_MODELS" "${EXTRA_CONFIGS[@]}"
  fi

  # OpenAI (if Azure is not configured)
  if [ -z "$AZURE_API_KEY" ]; then
    initializeLlmProviderConfig openai openai OPENAI api.openai.com "443" "https" "" "$OPENAI_MODELS"
  fi

  # OpenRouter - multi-provider router, supports custom models
  if [ -n "$OPENROUTER_API_KEY" ]; then
    initializeLlmProviderConfig openrouter openrouter OPENROUTER openrouter.ai "443" "https" "" "$OPENROUTER_MODELS"
  fi

  # Other providers (alphabetically ordered)
  initializeLlmProviderConfig yi yi YI api.lingyiwanwu.com "443" "https" "" "$YI_MODELS"
  
  initializeLlmProviderConfig ai360 ai360 AI360 api.360.cn "443" "https" "" "$AI360_MODELS"
  
  initializeLlmProviderConfig baichuan baichuan BAICHUAN api.baichuan-ai.com "443" "https" "" "$BAICHUAN_MODELS"
  
  initializeLlmProviderConfig baidu baidu BAIDU qianfan.baidubce.com "443" "https" "" "$BAIDU_MODELS"
  
  parseExtraConfigs "CLAUDE_EXTRA_CONFIGS"
  if [ ${#EXTRA_CONFIGS[@]} -eq 0 ]; then
    # Fallback to individual env vars for backward compatibility
    if [ -z "$CLAUDE_VERSION" ]; then
      CLAUDE_VERSION="2023-06-01"
    fi
    EXTRA_CONFIGS=("claudeVersion=\"$CLAUDE_VERSION\"")
    if [ -n "$CLAUDE_CODE_API_KEY" ]; then
      EXTRA_CONFIGS+=("claudeCodeMode=true")
    fi
  fi
  initializeLlmProviderConfig claude claude CLAUDE api.anthropic.com "443" "https" "" "$CLAUDE_MODELS" "${EXTRA_CONFIGS[@]}"

  # Cloudflare Workers AI
  if [ -n "$CLOUDFLARE_CONFIGURED" ]; then
    parseExtraConfigs "CLOUDFLARE_EXTRA_CONFIGS"
    if [ ${#EXTRA_CONFIGS[@]} -eq 0 ] && [ -n "$CLOUDFLARE_ACCOUNT_ID" ]; then
      EXTRA_CONFIGS=("cloudflareAccountId=\"$CLOUDFLARE_ACCOUNT_ID\"")
    fi
    initializeLlmProviderConfig cloudflare cloudflare CLOUDFLARE api.cloudflare.com "443" "https" "" "$CLOUDFLARE_MODELS" "${EXTRA_CONFIGS[@]}"
  fi

  initializeLlmProviderConfig cohere cohere COHERE api.cohere.com "443" "https" "" "$COHERE_MODELS"

  # DeepL - translation service
  if [ -n "$DEEPL_CONFIGURED" ]; then
    parseExtraConfigs "DEEPL_EXTRA_CONFIGS"
    if [ ${#EXTRA_CONFIGS[@]} -eq 0 ] && [ -n "$DEEPL_TARGET_LANG" ]; then
      EXTRA_CONFIGS=("targetLang=\"$DEEPL_TARGET_LANG\"")
    fi
    initializeLlmProviderConfig deepl deepl DEEPL api.deepl.com "443" "https" "" "$DEEPL_MODELS" "${EXTRA_CONFIGS[@]}"
  fi

  # Dify - AI workflow platform
  if [ -n "$DIFY_API_KEY" ]; then
    parseExtraConfigs "DIFY_EXTRA_CONFIGS"
    local DIFY_URL_VAL=$(getExtraConfigValue "difyApiUrl" "$DIFY_API_URL")
    if [ -n "$DIFY_URL_VAL" ]; then
      extractHostFromUrl "$DIFY_URL_VAL"
      local DIFY_DOMAIN="$HOST"
    else
      local DIFY_DOMAIN="api.dify.ai"
    fi
    if [ ${#EXTRA_CONFIGS[@]} -eq 0 ]; then
      # Fallback to individual env vars for backward compatibility
      if [ -n "$DIFY_BOT_TYPE" ]; then
        EXTRA_CONFIGS+=("botType=\"$DIFY_BOT_TYPE\"")
      fi
      if [ -n "$DIFY_INPUT_VARIABLE" ]; then
        EXTRA_CONFIGS+=("inputVariable=\"$DIFY_INPUT_VARIABLE\"")
      fi
      if [ -n "$DIFY_OUTPUT_VARIABLE" ]; then
        EXTRA_CONFIGS+=("outputVariable=\"$DIFY_OUTPUT_VARIABLE\"")
      fi
    fi
    initializeLlmProviderConfig dify dify DIFY "$DIFY_DOMAIN" "443" "https" "" "$DIFY_MODELS" "${EXTRA_CONFIGS[@]}"
  fi

  initializeLlmProviderConfig doubao doubao DOUBAO ark.cn-beijing.volces.com "443" "https" "" "$DOUBAO_MODELS"

  # Fireworks AI - fast inference
  if [ -n "$FIREWORKS_API_KEY" ]; then
    initializeLlmProviderConfig fireworks fireworks FIREWORKS api.fireworks.ai "443" "https" "" "$FIREWORKS_MODELS"
  fi

  # GitHub Models
  if [ -n "$GITHUB_API_KEY" ]; then
    initializeLlmProviderConfig github github GITHUB models.inference.ai.azure.com "443" "https" "" "$GITHUB_MODELS"
  fi

  initializeLlmProviderConfig gemini gemini GEMINI generativelanguage.googleapis.com "443" "https" "" "$GEMINI_MODELS"

  # Grok - xAI's model
  if [ -n "$GROK_API_KEY" ]; then
    initializeLlmProviderConfig grok grok GROK api.x.ai "443" "https" "" "$GROK_MODELS"
  fi

  # Groq - fast inference
  if [ -n "$GROQ_API_KEY" ]; then
    initializeLlmProviderConfig groq groq GROQ api.groq.com "443" "https" "" "$GROQ_MODELS"
  fi

  initializeLlmProviderConfig mistral mistral MISTRAL api.mistral.ai "443" "https" "" "$MISTRAL_MODELS"

  parseExtraConfigs "OLLAMA_EXTRA_CONFIGS"
  local OLLAMA_HOST_VAL=$(getExtraConfigValue "ollamaServerHost" "${OLLAMA_SERVER_HOST:-YOUR_OLLAMA_SERVER_HOST}")
  local OLLAMA_PORT_VAL=$(getExtraConfigValue "ollamaServerPort" "${OLLAMA_SERVER_PORT:-11434}")
  if [ ${#EXTRA_CONFIGS[@]} -eq 0 ]; then
    EXTRA_CONFIGS=(
      "ollamaServerHost=\"$OLLAMA_HOST_VAL\""
      "ollamaServerPort=$OLLAMA_PORT_VAL"
    )
  fi
  initializeLlmProviderConfig ollama ollama OLLAMA "$OLLAMA_HOST_VAL" "$OLLAMA_PORT_VAL" "http" "" "$OLLAMA_MODELS" "${EXTRA_CONFIGS[@]}"

  # iFlyTek Spark
  if [ -n "$SPARK_CONFIGURED" ]; then
    initializeLlmProviderConfig spark spark SPARK spark-api-open.xf-yun.com "443" "https" "" "$SPARK_MODELS"
  fi

  initializeLlmProviderConfig stepfun stepfun STEPFUN api.stepfun.com "443" "https" "" "$STEPFUN_MODELS"

  # Tencent Hunyuan
  if [ -n "$HUNYUAN_CONFIGURED" ]; then
    parseExtraConfigs "HUNYUAN_EXTRA_CONFIGS"
    if [ ${#EXTRA_CONFIGS[@]} -eq 0 ]; then
      # Fallback to individual env vars for backward compatibility
      if [ -n "$HUNYUAN_AUTH_ID" ]; then
        EXTRA_CONFIGS+=("hunyuanAuthId=\"$HUNYUAN_AUTH_ID\"")
      fi
      if [ -n "$HUNYUAN_AUTH_KEY" ]; then
        EXTRA_CONFIGS+=("hunyuanAuthKey=\"$HUNYUAN_AUTH_KEY\"")
      fi
    fi
    initializeLlmProviderConfig hunyuan hunyuan HUNYUAN hunyuan.tencentcloudapi.com "443" "https" "" "$HUNYUAN_MODELS" "${EXTRA_CONFIGS[@]}"
  fi

  # Together AI - open model hosting
  if [ -n "$TOGETHERAI_API_KEY" ]; then
    initializeLlmProviderConfig togetherai togetherai TOGETHERAI api.together.xyz "443" "https" "" "$TOGETHERAI_MODELS"
  fi
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
  local MODELS="$1"
  shift
  local EXTRA_CONFIGS=("$@")

  local MODEL_MATCH_TYPE
  local MODEL_MATCH_VALUE
  IFS='|' read -r MODEL_MATCH_TYPE MODEL_MATCH_VALUE <<< "$(normalizeModelPattern "$MODELS")"

  appendAiRegistry "$NAME" "$DOMAIN" "$PORT" "$PROTOCOL"
  appendAiProxyConfigs "$NAME" "$TYPE" "$API_KEY_PREFIX" "$DEFAULT_API_KEY" "${EXTRA_CONFIGS[@]}"
  generateAiIngress "$NAME" "$MODEL_MATCH_TYPE" "$MODEL_MATCH_VALUE"
  generateAiRoute "$NAME" "$MODEL_MATCH_TYPE" "$MODEL_MATCH_VALUE"
}

function initializeSharedConfigs() {
  initializeWasmPlugins
  initializeMcpBridge
  initializeConsole
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
  url: http://localhost:8002/plugins/ai-proxy/1.0.0/plugin.wasm" >"$WASM_PLUGIN_CONFIG_FOLDER/ai-proxy.internal.yaml"

  echo -e "\
apiVersion: extensions.higress.io/v1alpha1
kind: WasmPlugin
metadata:
  annotations:
    higress.io/wasm-plugin-title: AI Statistics
  labels:
    higress.io/resource-definer: higress
    higress.io/wasm-plugin-built-in: \"true\"
    higress.io/wasm-plugin-category: ai
    higress.io/wasm-plugin-name: ai-statistics
    higress.io/wasm-plugin-version: 1.0.0
  name: ai-statistics-1.0.0
  namespace: higress-system
  resourceVersion: \"1\"
spec:
  defaultConfig:
    use_default_attributes: true
  defaultConfigDisable: false
  failStrategy: FAIL_OPEN
  phase: UNSPECIFIED_PHASE
  priority: 900
  url: http://localhost:8002/plugins/ai-statistics/1.0.0/plugin.wasm" >"$WASM_PLUGIN_CONFIG_FOLDER/ai-statistics-1.0.0.yaml"

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
    modelToHeader: x-higress-llm-model
  defaultConfigDisable: false
  failStrategy: FAIL_OPEN
  phase: AUTHN
  priority: 900
  url: http://localhost:8002/plugins/model-router/1.0.0/plugin.wasm" >"$WASM_PLUGIN_CONFIG_FOLDER/model-router.internal.yaml"
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

function initializeConsole() {
  sed -i -E 's|index.redirect-target:.*$|index.redirect-target: /ai/route|' /data/configmaps/higress-console.yaml
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
  local MODEL_MATCH_TYPE="$2"
  local MODEL_MATCH_VALUE="$3"

  local INGRESS_NAME="ai-route-$PROVIDER_NAME.internal"
  local INGRESS_FILE="/data/ingresses/$INGRESS_NAME.yaml"

  mkdir -p /data/ingresses

  local HEADER_MATCH_ANNOTATION_PREFIX="unknown"
  if [ "$MODEL_MATCH_TYPE" == "PRE" ]; then
    HEADER_MATCH_ANNOTATION_PREFIX="prefix"
  elif [ "$MODEL_MATCH_TYPE" == "REGULAR" ]; then
    HEADER_MATCH_ANNOTATION_PREFIX="regex"
  fi

  cat <<EOF >"$INGRESS_FILE"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    higress.io/destination: "$LAST_SERVICE_NAME:$LAST_SERVICE_PORT"
    higress.io/ignore-path-case: "false"
    higress.io/$HEADER_MATCH_ANNOTATION_PREFIX-match-header-x-higress-llm-model: "$MODEL_MATCH_VALUE"
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

  GENERATED_INGRESSES+=("$INGRESS_NAME")
}

function generateAiRoute() {
  local ROUTE_NAME="$1"
  local MODEL_MATCH_TYPE="$2"
  local MODEL_MATCH_VALUE="$3"

  local CONFIG_MAP_NAME="ai-route-$ROUTE_NAME"
  local CONFIG_MAP_FILE="/data/configmaps/$CONFIG_MAP_NAME.yaml"

  mkdir -p /data/configmaps

  local modelPredicatesJson=""
  if [ "$MODEL_MATCH_TYPE" == "REGULAR" ]; then
    # REGULAR: split into multiple predicates
    IFS='|' read -ra patterns <<< "$MODEL_MATCH_VALUE"
    local predicates=()
    for pattern in "${patterns[@]}"; do
      if [[ "$pattern" =~ \.\*$ ]]; then
        # Ends with .*, use PRE match
        local prefixValue="${pattern%.*}"  # Remove trailing .*
        predicates+=("{\"matchType\": \"PRE\", \"matchValue\": \"$prefixValue\"}")
      else
        # Other cases, EXACT match, but use PRE match for simplicity
        predicates+=("{\"matchType\": \"PRE\", \"matchValue\": \"$pattern\"}")
      fi
    done
    modelPredicatesJson="["
    local first=1
    for pred in "${predicates[@]}"; do
      if [ $first -eq 1 ]; then
        first=0
      else
        modelPredicatesJson+=","
      fi
      modelPredicatesJson+=$'\n'"        $pred"
    done
    modelPredicatesJson+=$'\n'"      ]"
  else
    # Other cases, single predicate
    modelPredicatesJson="[{\"matchType\": \"$MODEL_MATCH_TYPE\", \"matchValue\": \"$MODEL_MATCH_VALUE\"}]"
  fi

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
      "modelPredicates": $modelPredicatesJson,
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
