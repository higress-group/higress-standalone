#!/bin/bash

cd "$(dirname -- "$0")"
ROOT=$(pwd)
cd - >/dev/null
source $ROOT/../base.sh

AI_PROXY_VERSION=${AI_PROXY_VERSION:-1.0.0}
AI_STATISTICS_VERSION=${AI_STATISTICS_VERSION:-1.0.0}
MODEL_ROUTER_VERSION=${MODEL_ROUTER_VERSION:-1.0.0}

declare -a GENERATED_INGRESSES

function initializeLlmProviderConfigs() {
  local EXTRA_CONFIGS=()

  # Top commonly used providers (matching get-ai-gateway.sh order)
  local DASHSCOPE_MODELS="${DASHSCOPE_MODELS:-qwen}"
  initializeLlmProviderConfig aliyun qwen DASHSCOPE dashscope.aliyuncs.com "443" "https" "" "PRE" "$DASHSCOPE_MODELS"
  
  local DEEPSEEK_MODELS="${DEEPSEEK_MODELS:-deepseek}"
  initializeLlmProviderConfig deepseek deepseek DEEPSEEK api.deepseek.com "443" "https" "" "PRE" "$DEEPSEEK_MODELS"
  
  local MOONSHOT_MODELS="${MOONSHOT_MODELS:-moonshot-.*|kimi-.*}"
  initializeLlmProviderConfig moonshot moonshot MOONSHOT api.moonshot.cn "443" "https" "" "REGULAR" "$MOONSHOT_MODELS"
  
  local ZHIPUAI_MODELS="${ZHIPUAI_MODELS:-GLM-}"
  initializeLlmProviderConfig zhipuai zhipuai ZHIPUAI open.bigmodel.cn "443" "https" "" "PRE" "$ZHIPUAI_MODELS"
  
  EXTRA_CONFIGS=(
    "minimaxGroupId=\"$MINIMAX_GROUP_ID\""
  )
  local MINIMAX_MODELS="${MINIMAX_MODELS:-abab}"
  initializeLlmProviderConfig minimax minimax MINIMAX api.minimax.chat "443" "https" "" "PRE" "$MINIMAX_MODELS" "${EXTRA_CONFIGS[@]}"

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
    local AZURE_MODELS="${AZURE_MODELS:-gpt-.*|o1-.*|o3-.*}"
    initializeLlmProviderConfig azure azure AZURE "$AZURE_SERVICE_DOMAIN" "443" "https" "" "REGULAR" "$AZURE_MODELS" "${EXTRA_CONFIGS[@]}"
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
    # Support custom model patterns via environment variable
    local BEDROCK_MODELS="${BEDROCK_MODELS:-.*}"
    initializeLlmProviderConfig bedrock bedrock BEDROCK bedrock-runtime.${BEDROCK_REGION:-us-east-1}.amazonaws.com "443" "https" "" "REGULAR" "$BEDROCK_MODELS" "${EXTRA_CONFIGS[@]}"
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
    # Support custom model patterns via environment variable
    local VERTEX_MODELS="${VERTEX_MODELS:-gemini-.*}"
    initializeLlmProviderConfig vertex vertex VERTEX ${VERTEX_REGION:-us-central1}-aiplatform.googleapis.com "443" "https" "" "REGULAR" "$VERTEX_MODELS" "${EXTRA_CONFIGS[@]}"
  fi

  # OpenAI (if Azure is not configured)
  if [ -z "$AZURE_API_KEY" ]; then
    local OPENAI_MODELS="${OPENAI_MODELS:-gpt-.*|o1-.*|o3-.*}"
    initializeLlmProviderConfig openai openai OPENAI api.openai.com "443" "https" "" "REGULAR" "$OPENAI_MODELS"
  fi

  # OpenRouter - multi-provider router, supports custom models
  if [ -n "$OPENROUTER_API_KEY" ]; then
    local OPENROUTER_MODELS="${OPENROUTER_MODELS:-.*}"
    initializeLlmProviderConfig openrouter openrouter OPENROUTER openrouter.ai "443" "https" "" "REGULAR" "$OPENROUTER_MODELS"
  fi

  # Other providers (alphabetically ordered)
  local YI_MODELS="${YI_MODELS:-yi-}"
  initializeLlmProviderConfig yi yi YI api.lingyiwanwu.com "443" "https" "" "PRE" "$YI_MODELS"
  
  local AI360_MODELS="${AI360_MODELS:-360GPT}"
  initializeLlmProviderConfig ai360 ai360 AI360 api.360.cn "443" "https" "" "PRE" "$AI360_MODELS"
  
  local BAICHUAN_MODELS="${BAICHUAN_MODELS:-Baichuan}"
  initializeLlmProviderConfig baichuan baichuan BAICHUAN api.baichuan-ai.com "443" "https" "" "PRE" "$BAICHUAN_MODELS"
  
  local BAIDU_MODELS="${BAIDU_MODELS:-ERNIE-}"
  initializeLlmProviderConfig baidu baidu BAIDU qianfan.baidubce.com "443" "https" "" "PRE" "$BAIDU_MODELS"
  
  if [ -z "$CLAUDE_VERSION" ]; then
    CLAUDE_VERSION="2023-06-01"
  fi
  EXTRA_CONFIGS=(
    "claudeVersion=\"$CLAUDE_VERSION\""
  )
  local CLAUDE_MODELS="${CLAUDE_MODELS:-claude-}"
  initializeLlmProviderConfig claude claude CLAUDE api.anthropic.com "443" "https" "" "PRE" "$CLAUDE_MODELS" "${EXTRA_CONFIGS[@]}"

  # Cloudflare Workers AI
  if [ -n "$CLOUDFLARE_CONFIGURED" ]; then
    EXTRA_CONFIGS=()
    if [ -n "$CLOUDFLARE_ACCOUNT_ID" ]; then
      EXTRA_CONFIGS+=("accountId=\"$CLOUDFLARE_ACCOUNT_ID\"")
    fi
    local CLOUDFLARE_MODELS="${CLOUDFLARE_MODELS:-.*}"
    initializeLlmProviderConfig cloudflare cloudflare CLOUDFLARE api.cloudflare.com "443" "https" "" "REGULAR" "$CLOUDFLARE_MODELS" "${EXTRA_CONFIGS[@]}"
  fi

  local COHERE_MODELS="${COHERE_MODELS:-command|command-.*}"
  initializeLlmProviderConfig cohere cohere COHERE api.cohere.com "443" "https" "" "REGULAR" "$COHERE_MODELS"

  # DeepL - translation service
  if [ -n "$DEEPL_CONFIGURED" ]; then
    EXTRA_CONFIGS=()
    if [ -n "$DEEPL_TARGET_LANG" ]; then
      EXTRA_CONFIGS+=("targetLang=\"$DEEPL_TARGET_LANG\"")
    fi
    local DEEPL_MODELS="${DEEPL_MODELS:-.*}"
    initializeLlmProviderConfig deepl deepl DEEPL api.deepl.com "443" "https" "" "REGULAR" "$DEEPL_MODELS" "${EXTRA_CONFIGS[@]}"
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
    local DIFY_MODELS="${DIFY_MODELS:-.*}"
    initializeLlmProviderConfig dify dify DIFY "$DIFY_DOMAIN" "443" "https" "" "REGULAR" "$DIFY_MODELS" "${EXTRA_CONFIGS[@]}"
  fi

  local DOUBAO_MODELS="${DOUBAO_MODELS:-doubao-}"
  initializeLlmProviderConfig doubao doubao DOUBAO ark.cn-beijing.volces.com "443" "https" "" "PRE" "$DOUBAO_MODELS"

  # Fireworks AI - fast inference
  if [ -n "$FIREWORKS_API_KEY" ]; then
    local FIREWORKS_MODELS="${FIREWORKS_MODELS:-.*}"
    initializeLlmProviderConfig fireworks fireworks FIREWORKS api.fireworks.ai "443" "https" "" "REGULAR" "$FIREWORKS_MODELS"
  fi

  # GitHub Models
  if [ -n "$GITHUB_API_KEY" ]; then
    local GITHUB_MODELS="${GITHUB_MODELS:-.*}"
    initializeLlmProviderConfig github github GITHUB models.inference.ai.azure.com "443" "https" "" "REGULAR" "$GITHUB_MODELS"
  fi

  local GEMINI_MODELS="${GEMINI_MODELS:-gemini-}"
  initializeLlmProviderConfig gemini gemini GEMINI generativelanguage.googleapis.com "443" "https" "" "PRE" "$GEMINI_MODELS"

  # Grok - xAI's model
  if [ -n "$GROK_API_KEY" ]; then
    local GROK_MODELS="${GROK_MODELS:-grok-.*}"
    initializeLlmProviderConfig grok grok GROK api.x.ai "443" "https" "" "REGULAR" "$GROK_MODELS"
  fi

  # Groq - fast inference
  if [ -n "$GROQ_API_KEY" ]; then
    local GROQ_MODELS="${GROQ_MODELS:-.*}"
    initializeLlmProviderConfig groq groq GROQ api.groq.com "443" "https" "" "REGULAR" "$GROQ_MODELS"
  fi

  local MISTRAL_MODELS="${MISTRAL_MODELS:-open-mistral-.*|mistral-.*}"
  initializeLlmProviderConfig mistral mistral MISTRAL api.mistral.ai "443" "https" "" "REGULAR" "$MISTRAL_MODELS"

  if [ -z "$OLLAMA_SERVER_HOST" ]; then
    OLLAMA_SERVER_HOST="YOUR_OLLAMA_SERVER_HOST"
  fi
  OLLAMA_SERVER_PORT="${OLLAMA_SERVER_PORT:-11434}"
  EXTRA_CONFIGS=(
    "ollamaServerHost=\"$OLLAMA_SERVER_HOST\""
    "ollamaServerPort=$OLLAMA_SERVER_PORT"
  )
  local OLLAMA_MODELS="${OLLAMA_MODELS:-codellama.*|llama.*}"
  initializeLlmProviderConfig ollama ollama OLLAMA "$OLLAMA_SERVER_HOST" "$OLLAMA_SERVER_PORT" "http" "" "REGULAR" "$OLLAMA_MODELS" "${EXTRA_CONFIGS[@]}"

  # iFlyTek Spark
  if [ -n "$SPARK_CONFIGURED" ]; then
    local SPARK_MODELS="${SPARK_MODELS:-.*}"
    initializeLlmProviderConfig spark spark SPARK spark-api-open.xf-yun.com "443" "https" "" "REGULAR" "$SPARK_MODELS"
  fi

  local STEPFUN_MODELS="${STEPFUN_MODELS:-step-}"
  initializeLlmProviderConfig stepfun stepfun STEPFUN api.stepfun.com "443" "https" "" "PRE" "$STEPFUN_MODELS"

  # Tencent Hunyuan
  if [ -n "$HUNYUAN_CONFIGURED" ]; then
    EXTRA_CONFIGS=()
    if [ -n "$HUNYUAN_AUTH_ID" ]; then
      EXTRA_CONFIGS+=("authId=\"$HUNYUAN_AUTH_ID\"")
    fi
    if [ -n "$HUNYUAN_AUTH_KEY" ]; then
      EXTRA_CONFIGS+=("authKey=\"$HUNYUAN_AUTH_KEY\"")
    fi
    local HUNYUAN_MODELS="${HUNYUAN_MODELS:-hunyuan-.*}"
    initializeLlmProviderConfig hunyuan hunyuan HUNYUAN hunyuan.tencentcloudapi.com "443" "https" "" "REGULAR" "$HUNYUAN_MODELS" "${EXTRA_CONFIGS[@]}"
  fi

  # Together AI - open model hosting
  if [ -n "$TOGETHERAI_API_KEY" ]; then
    local TOGETHERAI_MODELS="${TOGETHERAI_MODELS:-.*}"
    initializeLlmProviderConfig togetherai togetherai TOGETHERAI api.together.xyz "443" "https" "" "REGULAR" "$TOGETHERAI_MODELS"
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
  url: oci://higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/ai-proxy:2.0.0" >"$WASM_PLUGIN_CONFIG_FOLDER/ai-proxy.internal.yaml"

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
  url: oci://higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/ai-statistics:2.0.0" >"$WASM_PLUGIN_CONFIG_FOLDER/ai-statistics-1.0.0.yaml"

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
  url: oci://higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/model-router:2.0.0" >"$WASM_PLUGIN_CONFIG_FOLDER/model-router.internal.yaml"
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
