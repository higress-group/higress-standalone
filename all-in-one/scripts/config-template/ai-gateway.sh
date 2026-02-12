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
      # Remove surrounding quotes
      value="${value//\"/}"
      echo "$value"
      return
    fi
  done
  echo "$default"
}

function initializeLlmProviderConfigs() {
  # Top commonly used providers (defaults set in get-ai-gateway.sh)
  local DASHSCOPE_MODELS="${DASHSCOPE_MODELS}"
  IFS='|' read -r DASHSCOPE_TYPE DASHSCOPE_PATTERN <<< "$(normalizeModelPattern "$DASHSCOPE_MODELS")"
  initializeLlmProviderConfig aliyun qwen DASHSCOPE dashscope.aliyuncs.com "443" "https" "" "$DASHSCOPE_TYPE" "$DASHSCOPE_PATTERN"
  
  local DEEPSEEK_MODELS="${DEEPSEEK_MODELS}"
  IFS='|' read -r DEEPSEEK_TYPE DEEPSEEK_PATTERN <<< "$(normalizeModelPattern "$DEEPSEEK_MODELS")"
  initializeLlmProviderConfig deepseek deepseek DEEPSEEK api.deepseek.com "443" "https" "" "$DEEPSEEK_TYPE" "$DEEPSEEK_PATTERN"
  
  local MOONSHOT_MODELS="${MOONSHOT_MODELS}"
  IFS='|' read -r MOONSHOT_TYPE MOONSHOT_PATTERN <<< "$(normalizeModelPattern "$MOONSHOT_MODELS")"
  initializeLlmProviderConfig moonshot moonshot MOONSHOT api.moonshot.cn "443" "https" "" "$MOONSHOT_TYPE" "$MOONSHOT_PATTERN"
  
  # ZhipuAI - supports domain and code plan mode via EXTRA_CONFIGS
  local ZHIPUAI_MODELS="${ZHIPUAI_MODELS}"
  IFS='|' read -r ZHIPUAI_TYPE ZHIPUAI_PATTERN <<< "$(normalizeModelPattern "$ZHIPUAI_MODELS")"
  parseExtraConfigs "ZHIPUAI_EXTRA_CONFIGS"
  local ZHIPUAI_HOST=$(getExtraConfigValue "zhipuDomain" "open.bigmodel.cn")
  initializeLlmProviderConfig zhipuai zhipuai ZHIPUAI "$ZHIPUAI_HOST" "443" "https" "" "$ZHIPUAI_TYPE" "$ZHIPUAI_PATTERN" "${EXTRA_CONFIGS[@]}"
  
  # Minimax
  local MINIMAX_MODELS="${MINIMAX_MODELS}"
  IFS='|' read -r MINIMAX_TYPE MINIMAX_PATTERN <<< "$(normalizeModelPattern "$MINIMAX_MODELS")"
  parseExtraConfigs "MINIMAX_EXTRA_CONFIGS"
  initializeLlmProviderConfig minimax minimax MINIMAX api.minimax.chat "443" "https" "" "$MINIMAX_TYPE" "$MINIMAX_PATTERN" "${EXTRA_CONFIGS[@]}"

  # Azure OpenAI
  if [ -z "$OPENAI_API_KEY" ]; then
    parseExtraConfigs "AZURE_EXTRA_CONFIGS"
    local AZURE_SERVICE_URL_VAL=$(getExtraConfigValue "azureServiceUrl" "")
    if [ -z "$AZURE_SERVICE_URL_VAL" ]; then
      AZURE_SERVICE_URL_VAL="https://YOUR_RESOURCE_NAME.openai.azure.com/openai/deployments/YOUR_DEPLOYMENT_NAME/chat/completions?api-version=2024-06-01"
    fi
    extractHostFromUrl "$AZURE_SERVICE_URL_VAL"
    local AZURE_SERVICE_DOMAIN="$HOST"
    local AZURE_MODELS="${AZURE_MODELS}"
    IFS='|' read -r AZURE_TYPE AZURE_PATTERN <<< "$(normalizeModelPattern "$AZURE_MODELS")"
    initializeLlmProviderConfig azure azure AZURE "$AZURE_SERVICE_DOMAIN" "443" "https" "" "$AZURE_TYPE" "$AZURE_PATTERN" "${EXTRA_CONFIGS[@]}"
  fi

  # AWS Bedrock - requires region configuration
  if [ -n "$BEDROCK_CONFIGURED" ]; then
    parseExtraConfigs "BEDROCK_EXTRA_CONFIGS"
    local BEDROCK_REGION_VAL=$(getExtraConfigValue "awsRegion" "us-east-1")
    local BEDROCK_MODELS="${BEDROCK_MODELS}"
    IFS='|' read -r BEDROCK_TYPE BEDROCK_PATTERN <<< "$(normalizeModelPattern "$BEDROCK_MODELS")"
    initializeLlmProviderConfig bedrock bedrock BEDROCK bedrock-runtime.${BEDROCK_REGION_VAL}.amazonaws.com "443" "https" "" "$BEDROCK_TYPE" "$BEDROCK_PATTERN" "${EXTRA_CONFIGS[@]}"
  fi

  # Google Vertex AI - requires project and region configuration
  if [ -n "$VERTEX_CONFIGURED" ]; then
    parseExtraConfigs "VERTEX_EXTRA_CONFIGS"
    local VERTEX_REGION_VAL=$(getExtraConfigValue "vertexRegion" "us-central1")
    local VERTEX_MODELS="${VERTEX_MODELS}"
    IFS='|' read -r VERTEX_TYPE VERTEX_PATTERN <<< "$(normalizeModelPattern "$VERTEX_MODELS")"
    initializeLlmProviderConfig vertex vertex VERTEX ${VERTEX_REGION_VAL}-aiplatform.googleapis.com "443" "https" "" "$VERTEX_TYPE" "$VERTEX_PATTERN" "${EXTRA_CONFIGS[@]}"
  fi

  # OpenAI (if Azure is not configured)
  if [ -z "$AZURE_API_KEY" ]; then
    local OPENAI_MODELS="${OPENAI_MODELS}"
    IFS='|' read -r OPENAI_TYPE OPENAI_PATTERN <<< "$(normalizeModelPattern "$OPENAI_MODELS")"
    initializeLlmProviderConfig openai openai OPENAI api.openai.com "443" "https" "" "$OPENAI_TYPE" "$OPENAI_PATTERN"
  fi

  # OpenRouter - multi-provider router, supports custom models
  if [ -n "$OPENROUTER_API_KEY" ]; then
    local OPENROUTER_MODELS="${OPENROUTER_MODELS}"
    IFS='|' read -r OPENROUTER_TYPE OPENROUTER_PATTERN <<< "$(normalizeModelPattern "$OPENROUTER_MODELS")"
    initializeLlmProviderConfig openrouter openrouter OPENROUTER openrouter.ai "443" "https" "" "$OPENROUTER_TYPE" "$OPENROUTER_PATTERN"
  fi

  # Other providers (alphabetically ordered)
  local YI_MODELS="${YI_MODELS}"
  IFS='|' read -r YI_TYPE YI_PATTERN <<< "$(normalizeModelPattern "$YI_MODELS")"
  initializeLlmProviderConfig yi yi YI api.lingyiwanwu.com "443" "https" "" "$YI_TYPE" "$YI_PATTERN"
  
  local AI360_MODELS="${AI360_MODELS}"
  IFS='|' read -r AI360_TYPE AI360_PATTERN <<< "$(normalizeModelPattern "$AI360_MODELS")"
  initializeLlmProviderConfig ai360 ai360 AI360 api.360.cn "443" "https" "" "$AI360_TYPE" "$AI360_PATTERN"
  
  local BAICHUAN_MODELS="${BAICHUAN_MODELS}"
  IFS='|' read -r BAICHUAN_TYPE BAICHUAN_PATTERN <<< "$(normalizeModelPattern "$BAICHUAN_MODELS")"
  initializeLlmProviderConfig baichuan baichuan BAICHUAN api.baichuan-ai.com "443" "https" "" "$BAICHUAN_TYPE" "$BAICHUAN_PATTERN"
  
  local BAIDU_MODELS="${BAIDU_MODELS}"
  IFS='|' read -r BAIDU_TYPE BAIDU_PATTERN <<< "$(normalizeModelPattern "$BAIDU_MODELS")"
  initializeLlmProviderConfig baidu baidu BAIDU qianfan.baidubce.com "443" "https" "" "$BAIDU_TYPE" "$BAIDU_PATTERN"
  
  # Claude
  local CLAUDE_MODELS="${CLAUDE_MODELS}"
  IFS='|' read -r CLAUDE_TYPE CLAUDE_PATTERN <<< "$(normalizeModelPattern "$CLAUDE_MODELS")"
  parseExtraConfigs "CLAUDE_EXTRA_CONFIGS"
  initializeLlmProviderConfig claude claude CLAUDE api.anthropic.com "443" "https" "" "$CLAUDE_TYPE" "$CLAUDE_PATTERN" "${EXTRA_CONFIGS[@]}"

  # Cloudflare Workers AI
  if [ -n "$CLOUDFLARE_CONFIGURED" ]; then
    local CLOUDFLARE_MODELS="${CLOUDFLARE_MODELS}"
    IFS='|' read -r CLOUDFLARE_TYPE CLOUDFLARE_PATTERN <<< "$(normalizeModelPattern "$CLOUDFLARE_MODELS")"
    parseExtraConfigs "CLOUDFLARE_EXTRA_CONFIGS"
    initializeLlmProviderConfig cloudflare cloudflare CLOUDFLARE api.cloudflare.com "443" "https" "" "$CLOUDFLARE_TYPE" "$CLOUDFLARE_PATTERN" "${EXTRA_CONFIGS[@]}"
  fi

  local COHERE_MODELS="${COHERE_MODELS}"
  IFS='|' read -r COHERE_TYPE COHERE_PATTERN <<< "$(normalizeModelPattern "$COHERE_MODELS")"
  initializeLlmProviderConfig cohere cohere COHERE api.cohere.com "443" "https" "" "$COHERE_TYPE" "$COHERE_PATTERN"

  # DeepL - translation service
  if [ -n "$DEEPL_CONFIGURED" ]; then
    local DEEPL_MODELS="${DEEPL_MODELS}"
    IFS='|' read -r DEEPL_TYPE DEEPL_PATTERN <<< "$(normalizeModelPattern "$DEEPL_MODELS")"
    parseExtraConfigs "DEEPL_EXTRA_CONFIGS"
    initializeLlmProviderConfig deepl deepl DEEPL api.deepl.com "443" "https" "" "$DEEPL_TYPE" "$DEEPL_PATTERN" "${EXTRA_CONFIGS[@]}"
  fi

  # Dify - AI workflow platform
  if [ -n "$DIFY_API_KEY" ]; then
    parseExtraConfigs "DIFY_EXTRA_CONFIGS"
    local DIFY_DOMAIN=$(getExtraConfigValue "difyApiUrl" "api.dify.ai")
    # If it's a full URL, extract host
    if [[ "$DIFY_DOMAIN" == http* ]]; then
      extractHostFromUrl "$DIFY_DOMAIN"
      DIFY_DOMAIN="$HOST"
    fi
    local DIFY_MODELS="${DIFY_MODELS}"
    IFS='|' read -r DIFY_TYPE DIFY_PATTERN <<< "$(normalizeModelPattern "$DIFY_MODELS")"
    initializeLlmProviderConfig dify dify DIFY "$DIFY_DOMAIN" "443" "https" "" "$DIFY_TYPE" "$DIFY_PATTERN" "${EXTRA_CONFIGS[@]}"
  fi

  local DOUBAO_MODELS="${DOUBAO_MODELS}"
  IFS='|' read -r DOUBAO_TYPE DOUBAO_PATTERN <<< "$(normalizeModelPattern "$DOUBAO_MODELS")"
  initializeLlmProviderConfig doubao doubao DOUBAO ark.cn-beijing.volces.com "443" "https" "" "$DOUBAO_TYPE" "$DOUBAO_PATTERN"

  # Fireworks AI - fast inference
  if [ -n "$FIREWORKS_API_KEY" ]; then
    local FIREWORKS_MODELS="${FIREWORKS_MODELS}"
    IFS='|' read -r FIREWORKS_TYPE FIREWORKS_PATTERN <<< "$(normalizeModelPattern "$FIREWORKS_MODELS")"
    initializeLlmProviderConfig fireworks fireworks FIREWORKS api.fireworks.ai "443" "https" "" "$FIREWORKS_TYPE" "$FIREWORKS_PATTERN"
  fi

  # GitHub Models
  if [ -n "$GITHUB_API_KEY" ]; then
    local GITHUB_MODELS="${GITHUB_MODELS}"
    IFS='|' read -r GITHUB_TYPE GITHUB_PATTERN <<< "$(normalizeModelPattern "$GITHUB_MODELS")"
    initializeLlmProviderConfig github github GITHUB models.inference.ai.azure.com "443" "https" "" "$GITHUB_TYPE" "$GITHUB_PATTERN"
  fi

  local GEMINI_MODELS="${GEMINI_MODELS}"
  IFS='|' read -r GEMINI_TYPE GEMINI_PATTERN <<< "$(normalizeModelPattern "$GEMINI_MODELS")"
  initializeLlmProviderConfig gemini gemini GEMINI generativelanguage.googleapis.com "443" "https" "" "$GEMINI_TYPE" "$GEMINI_PATTERN"

  # Grok - xAI's model
  if [ -n "$GROK_API_KEY" ]; then
    local GROK_MODELS="${GROK_MODELS}"
    IFS='|' read -r GROK_TYPE GROK_PATTERN <<< "$(normalizeModelPattern "$GROK_MODELS")"
    initializeLlmProviderConfig grok grok GROK api.x.ai "443" "https" "" "$GROK_TYPE" "$GROK_PATTERN"
  fi

  # Groq - fast inference
  if [ -n "$GROQ_API_KEY" ]; then
    local GROQ_MODELS="${GROQ_MODELS}"
    IFS='|' read -r GROQ_TYPE GROQ_PATTERN <<< "$(normalizeModelPattern "$GROQ_MODELS")"
    initializeLlmProviderConfig groq groq GROQ api.groq.com "443" "https" "" "$GROQ_TYPE" "$GROQ_PATTERN"
  fi

  local MISTRAL_MODELS="${MISTRAL_MODELS}"
  IFS='|' read -r MISTRAL_TYPE MISTRAL_PATTERN <<< "$(normalizeModelPattern "$MISTRAL_MODELS")"
  initializeLlmProviderConfig mistral mistral MISTRAL api.mistral.ai "443" "https" "" "$MISTRAL_TYPE" "$MISTRAL_PATTERN"

  # Ollama
  parseExtraConfigs "OLLAMA_EXTRA_CONFIGS"
  local OLLAMA_HOST=$(getExtraConfigValue "ollamaServerHost" "YOUR_OLLAMA_SERVER_HOST")
  local OLLAMA_PORT=$(getExtraConfigValue "ollamaServerPort" "11434")
  local OLLAMA_MODELS="${OLLAMA_MODELS}"
  IFS='|' read -r OLLAMA_TYPE OLLAMA_PATTERN <<< "$(normalizeModelPattern "$OLLAMA_MODELS")"
  initializeLlmProviderConfig ollama ollama OLLAMA "$OLLAMA_HOST" "$OLLAMA_PORT" "http" "" "$OLLAMA_TYPE" "$OLLAMA_PATTERN" "${EXTRA_CONFIGS[@]}"

  # iFlyTek Spark
  if [ -n "$SPARK_CONFIGURED" ]; then
    local SPARK_MODELS="${SPARK_MODELS}"
    IFS='|' read -r SPARK_TYPE SPARK_PATTERN <<< "$(normalizeModelPattern "$SPARK_MODELS")"
    initializeLlmProviderConfig spark spark SPARK spark-api-open.xf-yun.com "443" "https" "" "$SPARK_TYPE" "$SPARK_PATTERN"
  fi

  local STEPFUN_MODELS="${STEPFUN_MODELS}"
  IFS='|' read -r STEPFUN_TYPE STEPFUN_PATTERN <<< "$(normalizeModelPattern "$STEPFUN_MODELS")"
  initializeLlmProviderConfig stepfun stepfun STEPFUN api.stepfun.com "443" "https" "" "$STEPFUN_TYPE" "$STEPFUN_PATTERN"

  # Tencent Hunyuan
  if [ -n "$HUNYUAN_CONFIGURED" ]; then
    local HUNYUAN_MODELS="${HUNYUAN_MODELS}"
    IFS='|' read -r HUNYUAN_TYPE HUNYUAN_PATTERN <<< "$(normalizeModelPattern "$HUNYUAN_MODELS")"
    parseExtraConfigs "HUNYUAN_EXTRA_CONFIGS"
    initializeLlmProviderConfig hunyuan hunyuan HUNYUAN hunyuan.tencentcloudapi.com "443" "https" "" "$HUNYUAN_TYPE" "$HUNYUAN_PATTERN" "${EXTRA_CONFIGS[@]}"
  fi

  # Together AI - open model hosting
  if [ -n "$TOGETHERAI_API_KEY" ]; then
    local TOGETHERAI_MODELS="${TOGETHERAI_MODELS}"
    IFS='|' read -r TOGETHERAI_TYPE TOGETHERAI_PATTERN <<< "$(normalizeModelPattern "$TOGETHERAI_MODELS")"
    initializeLlmProviderConfig togetherai togetherai TOGETHERAI api.together.xyz "443" "https" "" "$TOGETHERAI_TYPE" "$TOGETHERAI_PATTERN"
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
  local MODEL_MATCH_TYPE="$1"
  shift
  local MODEL_MATCH_VALUE="$1"
  shift
  local EXTRA_CONFIGS=("$@")

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
  defaultConfigDisable: true
  matchRules: ${AI_PROXY_MATCH_RULES:-[]}
  defaultConfig:
    providers: ${AI_PROXY_PROVIDERS:-[]}
  phase: UNSPECIFIED_PHASE
  priority: 100
  url: oci://${PLUGIN_REGISTRY}/higress/ai-proxy:${AI_PROXY_VERSION}
" >"${WASM_PLUGIN_CONFIG_FOLDER}/ai-proxy.yaml"

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
  name: ai-statistics.internal
  namespace: higress-system
  resourceVersion: \"1\"
spec:
  defaultConfigDisable: false
  defaultConfig:
    enable: true
  phase: UNSPECIFIED_PHASE
  priority: 200
  url: oci://${PLUGIN_REGISTRY}/higress/ai-statistics:${AI_STATISTICS_VERSION}
" >"${WASM_PLUGIN_CONFIG_FOLDER}/ai-statistics.yaml"

  echo -e "\
apiVersion: extensions.higress.io/v1alpha1
kind: WasmPlugin
metadata:
  annotations:
    higress.io/wasm-plugin-title: Model Router
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
  defaultConfigDisable: false
  defaultConfig:
    enable: true
    addProviderHeader: X-LLM-Provider
  phase: UNSPECIFIED_PHASE
  priority: 500
  url: oci://${PLUGIN_REGISTRY}/higress/model-router:${MODEL_ROUTER_VERSION}
" >"${WASM_PLUGIN_CONFIG_FOLDER}/model-router.yaml"
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
  if [ -z "$PROTOCOL" ]; then
    PROTOCOL="https"
  fi
  local SERVICE_NAME="${PROVIDER_NAME}.dns"
  AI_REGISTRIES="$AI_REGISTRIES
  - domain: ${DOMAIN}
    name: ${SERVICE_NAME}
    port: ${PORT}
    type: dns"

  LAST_SERVICE_NAME="$SERVICE_NAME"
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

function generateAiIngress() {
  local PROVIDER_NAME="$1"
  local MODEL_MATCH_TYPE="$2"
  local MODEL_MATCH_VALUE="$3"

  local PROVIDER_ID="${PROVIDER_NAME}"
  local INGRESS_NAME="ai-route-${PROVIDER_ID}"

  # Check if ingress with same name already exists
  for existing in "${GENERATED_INGRESSES[@]}"; do
    if [ "$existing" == "$INGRESS_NAME" ]; then
      return
    fi
  done
  GENERATED_INGRESSES+=("$INGRESS_NAME")

  mkdir -p /data/ingresses
  cd /data/ingresses

  echo -e "\
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    higress.io/destination: ${PROVIDER_NAME}.dns
    higress.io/ignore-path-case: \"false\"
  labels:
    higress.io/resource-definer: higress
  name: ${INGRESS_NAME}
  namespace: higress-system
  resourceVersion: \"1\"
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
" >"${INGRESS_NAME}.yaml"

  cd -
}

function generateAiRoute() {
  local PROVIDER_NAME="$1"
  local MODEL_MATCH_TYPE="$2"
  local MODEL_MATCH_VALUE="$3"
  
  local PROVIDER_ID="${PROVIDER_NAME}"
  local ROUTE_NAME="ai-route-${PROVIDER_ID}"

  mkdir -p /data/http2rpcs
  cd /data/http2rpcs

  echo -e "\
apiVersion: networking.higress.io/v1
kind: Http2Rpc
metadata:
  labels:
    higress.io/resource-definer: higress
  name: ${ROUTE_NAME}
  namespace: higress-system
  resourceVersion: \"1\"
spec:
  modelService:
    isDefault: false
    match:
      type: ${MODEL_MATCH_TYPE}
      value: \"${MODEL_MATCH_VALUE}\"
    target:
      primary:
        weight: 100
        destination:
          ingressName: ${ROUTE_NAME}
" >"${ROUTE_NAME}.yaml"

  cd -
}

source $ROOT/ai-gateway.sh

initializeLlmProviderConfigs
initializeSharedConfigs
