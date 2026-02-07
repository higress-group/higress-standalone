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

function initializeLlmProviderConfigs() {
  local EXTRA_CONFIGS=()

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
  
  local ZHIPUAI_MODELS="${ZHIPUAI_MODELS}"
  IFS='|' read -r ZHIPUAI_TYPE ZHIPUAI_PATTERN <<< "$(normalizeModelPattern "$ZHIPUAI_MODELS")"
  initializeLlmProviderConfig zhipuai zhipuai ZHIPUAI open.bigmodel.cn "443" "https" "" "$ZHIPUAI_TYPE" "$ZHIPUAI_PATTERN"
  
  EXTRA_CONFIGS=(
    "minimaxGroupId=\"$MINIMAX_GROUP_ID\""
  )
  local MINIMAX_MODELS="${MINIMAX_MODELS}"
  IFS='|' read -r MINIMAX_TYPE MINIMAX_PATTERN <<< "$(normalizeModelPattern "$MINIMAX_MODELS")"
  initializeLlmProviderConfig minimax minimax MINIMAX api.minimax.chat "443" "https" "" "$MINIMAX_TYPE" "$MINIMAX_PATTERN" "${EXTRA_CONFIGS[@]}"

  # Azure OpenAI
  if [ -z "$OPENAI_API_KEY" ]; then
    if [ -z "$AZURE_SERVICE_URL" ]; then
      AZURE_SERVICE_URL="https://YOUR_RESOURCE_NAME.openai.azure.com/openai/deployments/YOUR_DEPLOYMENT_NAME/chat/completions?api-version=2024-06-01"
    fi
    extractHostFromUrl "$AZURE_SERVICE_URL"
    local AZURE_SERVICE_DOMAIN="$HOST"
    EXTRA_CONFIGS=(
      "azureServiceUrl=$AZURE_SERVICE_URL"
    )
    local AZURE_MODELS="${AZURE_MODELS}"
    IFS='|' read -r AZURE_TYPE AZURE_PATTERN <<< "$(normalizeModelPattern "$AZURE_MODELS")"
    initializeLlmProviderConfig azure azure AZURE "$AZURE_SERVICE_DOMAIN" "443" "https" "" "$AZURE_TYPE" "$AZURE_PATTERN" "${EXTRA_CONFIGS[@]}"
  fi

  # AWS Bedrock - requires region configuration
  if [ -n "$BEDROCK_CONFIGURED" ]; then
    EXTRA_CONFIGS=()
    if [ -n "$BEDROCK_REGION" ]; then
      EXTRA_CONFIGS+=("region=\"$BEDROCK_REGION\"")
    fi
    if [ -n "$BEDROCK_ACCESS_KEY" ] && [ -n "$BEDROCK_SECRET_KEY" ]; then
      EXTRA_CONFIGS+=("accessKeyId=\"$BEDROCK_ACCESS_KEY\"")
      EXTRA_CONFIGS+=("secretAccessKey=\"$BEDROCK_SECRET_KEY\"")
    fi
    local BEDROCK_MODELS="${BEDROCK_MODELS}"
    IFS='|' read -r BEDROCK_TYPE BEDROCK_PATTERN <<< "$(normalizeModelPattern "$BEDROCK_MODELS")"
    initializeLlmProviderConfig bedrock bedrock BEDROCK bedrock-runtime.${BEDROCK_REGION:-us-east-1}.amazonaws.com "443" "https" "" "$BEDROCK_TYPE" "$BEDROCK_PATTERN" "${EXTRA_CONFIGS[@]}"
  fi

  # Google Vertex AI - requires project and region configuration
  if [ -n "$VERTEX_CONFIGURED" ]; then
    EXTRA_CONFIGS=()
    if [ -n "$VERTEX_PROJECT_ID" ]; then
      EXTRA_CONFIGS+=("gcpProject=\"$VERTEX_PROJECT_ID\"")
    fi
    if [ -n "$VERTEX_REGION" ]; then
      EXTRA_CONFIGS+=("gcpRegion=\"$VERTEX_REGION\"")
    fi
    if [ -n "$VERTEX_AUTH_KEY" ]; then
      EXTRA_CONFIGS+=("serviceAccount=\"$VERTEX_AUTH_KEY\"")
    fi
    if [ -n "$VERTEX_AUTH_SERVICE_NAME" ]; then
      EXTRA_CONFIGS+=("serviceAccountName=\"$VERTEX_AUTH_SERVICE_NAME\"")
    fi
    local VERTEX_MODELS="${VERTEX_MODELS}"
    IFS='|' read -r VERTEX_TYPE VERTEX_PATTERN <<< "$(normalizeModelPattern "$VERTEX_MODELS")"
    initializeLlmProviderConfig vertex vertex VERTEX ${VERTEX_REGION:-us-central1}-aiplatform.googleapis.com "443" "https" "" "$VERTEX_TYPE" "$VERTEX_PATTERN" "${EXTRA_CONFIGS[@]}"
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
  
  if [ -z "$CLAUDE_VERSION" ]; then
    CLAUDE_VERSION="2023-06-01"
  fi
  EXTRA_CONFIGS=(
    "claudeVersion=\"$CLAUDE_VERSION\""
  )
  # Enable Claude Code mode if OAuth token is provided
  if [ -n "$CLAUDE_CODE_API_KEY" ]; then
    EXTRA_CONFIGS+=("claudeCodeMode=true")
  fi
  local CLAUDE_MODELS="${CLAUDE_MODELS}"
  IFS='|' read -r CLAUDE_TYPE CLAUDE_PATTERN <<< "$(normalizeModelPattern "$CLAUDE_MODELS")"
  initializeLlmProviderConfig claude claude CLAUDE api.anthropic.com "443" "https" "" "$CLAUDE_TYPE" "$CLAUDE_PATTERN" "${EXTRA_CONFIGS[@]}"

  # Cloudflare Workers AI
  if [ -n "$CLOUDFLARE_CONFIGURED" ]; then
    EXTRA_CONFIGS=()
    if [ -n "$CLOUDFLARE_ACCOUNT_ID" ]; then
      EXTRA_CONFIGS+=("accountId=\"$CLOUDFLARE_ACCOUNT_ID\"")
    fi
    local CLOUDFLARE_MODELS="${CLOUDFLARE_MODELS}"
    IFS='|' read -r CLOUDFLARE_TYPE CLOUDFLARE_PATTERN <<< "$(normalizeModelPattern "$CLOUDFLARE_MODELS")"
    initializeLlmProviderConfig cloudflare cloudflare CLOUDFLARE api.cloudflare.com "443" "https" "" "$CLOUDFLARE_TYPE" "$CLOUDFLARE_PATTERN" "${EXTRA_CONFIGS[@]}"
  fi

  local COHERE_MODELS="${COHERE_MODELS}"
  IFS='|' read -r COHERE_TYPE COHERE_PATTERN <<< "$(normalizeModelPattern "$COHERE_MODELS")"
  initializeLlmProviderConfig cohere cohere COHERE api.cohere.com "443" "https" "" "$COHERE_TYPE" "$COHERE_PATTERN"

  # DeepL - translation service
  if [ -n "$DEEPL_CONFIGURED" ]; then
    EXTRA_CONFIGS=()
    if [ -n "$DEEPL_TARGET_LANG" ]; then
      EXTRA_CONFIGS+=("targetLang=\"$DEEPL_TARGET_LANG\"")
    fi
    local DEEPL_MODELS="${DEEPL_MODELS}"
    IFS='|' read -r DEEPL_TYPE DEEPL_PATTERN <<< "$(normalizeModelPattern "$DEEPL_MODELS")"
    initializeLlmProviderConfig deepl deepl DEEPL api.deepl.com "443" "https" "" "$DEEPL_TYPE" "$DEEPL_PATTERN" "${EXTRA_CONFIGS[@]}"
  fi

  # Dify - AI workflow platform
  if [ -n "$DIFY_API_KEY" ]; then
    EXTRA_CONFIGS=()
    if [ -n "$DIFY_API_URL" ]; then
      extractHostFromUrl "$DIFY_API_URL"
      local DIFY_DOMAIN="$HOST"
    else
      local DIFY_DOMAIN="api.dify.ai"
    fi
    if [ -n "$DIFY_BOT_TYPE" ]; then
      EXTRA_CONFIGS+=("botType=\"$DIFY_BOT_TYPE\"")
    fi
    if [ -n "$DIFY_INPUT_VARIABLE" ]; then
      EXTRA_CONFIGS+=("inputVariable=\"$DIFY_INPUT_VARIABLE\"")
    fi
    if [ -n "$DIFY_OUTPUT_VARIABLE" ]; then
      EXTRA_CONFIGS+=("outputVariable=\"$DIFY_OUTPUT_VARIABLE\"")
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

  if [ -z "$OLLAMA_SERVER_HOST" ]; then
    OLLAMA_SERVER_HOST="YOUR_OLLAMA_SERVER_HOST"
  fi
  OLLAMA_SERVER_PORT="${OLLAMA_SERVER_PORT:-11434}"
  EXTRA_CONFIGS=(
    "ollamaServerHost=\"$OLLAMA_SERVER_HOST\""
    "ollamaServerPort=$OLLAMA_SERVER_PORT"
  )
  local OLLAMA_MODELS="${OLLAMA_MODELS}"
  IFS='|' read -r OLLAMA_TYPE OLLAMA_PATTERN <<< "$(normalizeModelPattern "$OLLAMA_MODELS")"
  initializeLlmProviderConfig ollama ollama OLLAMA "$OLLAMA_SERVER_HOST" "$OLLAMA_SERVER_PORT" "http" "" "$OLLAMA_TYPE" "$OLLAMA_PATTERN" "${EXTRA_CONFIGS[@]}"

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
    EXTRA_CONFIGS=()
    if [ -n "$HUNYUAN_AUTH_ID" ]; then
      EXTRA_CONFIGS+=("authId=\"$HUNYUAN_AUTH_ID\"")
    fi
    if [ -n "$HUNYUAN_AUTH_KEY" ]; then
      EXTRA_CONFIGS+=("authKey=\"$HUNYUAN_AUTH_KEY\"")
    fi
    local HUNYUAN_MODELS="${HUNYUAN_MODELS}"
    IFS='|' read -r HUNYUAN_TYPE HUNYUAN_PATTERN <<< "$(normalizeModelPattern "$HUNYUAN_MODELS")"
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
  defaultConfig:
    providers:${AI_PROXY_PROVIDERS}
  defaultConfigDisable: false
  matchRules:${AI_PROXY_MATCH_RULES}
  failStrategy: FAIL_OPEN
  phase: UNSPECIFIED_PHASE
  priority: 100
  url: oci://${PLUGIN_REGISTRY:-higress-registry.cn-hangzhou.cr.aliyuncs.com}/plugins/ai-proxy:2.0.0" >"$WASM_PLUGIN_CONFIG_FOLDER/ai-proxy.internal.yaml"

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
  url: oci://${PLUGIN_REGISTRY:-higress-registry.cn-hangzhou.cr.aliyuncs.com}/plugins/ai-statistics:2.0.0" >"$WASM_PLUGIN_CONFIG_FOLDER/ai-statistics-1.0.0.yaml"

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
  url: oci://${PLUGIN_REGISTRY:-higress-registry.cn-hangzhou.cr.aliyuncs.com}/plugins/model-router:2.0.0" >"$WASM_PLUGIN_CONFIG_FOLDER/model-router.internal.yaml"
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
      "modelPredicates": [
        {
          "matchType": "$MODEL_MATCH_TYPE",
          "matchValue": "$MODEL_MATCH_VALUE"
        }
      ],
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
