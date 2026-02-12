#!/usr/bin/env bash

#  Copyright (c) 2024 Alibaba Group Holding Ltd.

#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at

#       http:www.apache.org/licenses/LICENSE-2.0

#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

# Create a file descriptor for reading user input
exec 3</dev/tty

DOCKER_COMMAND="docker"

HAS_DOCKER="$(type "docker" &>/dev/null && echo true || echo false)"
if [ "${HAS_DOCKER}" != "true" ]; then
  echo "Docker is required"
  exit 1
fi

DEFAULT_CONTAINER_NAME=higress-ai-gateway
DEFAULT_IMAGE_REPO=higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/all-in-one
DEFAULT_PLUGIN_REGISTRY=higress-registry.cn-hangzhou.cr.aliyuncs.com
DEFAULT_IMAGE_TAG=latest
DEFAULT_GATEWAY_HTTP_PORT=8080
DEFAULT_GATEWAY_HTTPS_PORT=8443
DEFAULT_CONSOLE_PORT=8001

CONFIG_FILENAME="default.cfg"

COMMAND_START="start"
COMMAND_STOP="stop"
COMMAND_DELETE="delete"
COMMAND_ROUTE="route"
COMMAND_CONFIG="config"
KNOWN_COMMANDS=($COMMAND_START, $COMMAND_STOP, $COMMAND_DELETE, $COMMAND_ROUTE, $COMMAND_CONFIG)

# Route subcommands
ROUTE_ADD="add"
ROUTE_LIST="list"
ROUTE_REMOVE="remove"
KNOWN_ROUTE_SUBCOMMANDS=($ROUTE_ADD, $ROUTE_LIST, $ROUTE_REMOVE)

# Config subcommands
CONFIG_ADD="add"
CONFIG_LIST="list"
CONFIG_REMOVE="remove"
KNOWN_CONFIG_SUBCOMMANDS=($CONFIG_ADD, $CONFIG_LIST, $CONFIG_REMOVE)

cd "$(dirname -- "$0")"
ROOT="$(pwd -P)/higress"
SCRIPT_DIR="$(pwd -P)"
cd - >/dev/null

CONFIGURED_MARK="$ROOT/.configured"

# Auto-routing configuration
ENABLE_AUTO_ROUTING="false"
AUTO_ROUTING_DEFAULT_MODEL=""

initArch() {
  ARCH=$(uname -m)
  case $ARCH in
  armv5*) ARCH="armv5" ;;
  armv6*) ARCH="armv6" ;;
  armv7*) ARCH="arm" ;;
  aarch64) ARCH="arm64" ;;
  x86) ARCH="386" ;;
  x86_64) ARCH="amd64" ;;
  i686) ARCH="386" ;;
  i386) ARCH="386" ;;
  esac
}

initOS() {
  OS="$(uname | tr '[:upper:]' '[:lower:]')"
  case "$OS" in
  # Minimalist GNU for Windows
  mingw* | cygwin*) OS='windows' ;;
  esac
}

# Auto-detect timezone and select optimal plugin registry
detectPluginRegistry() {
  if [ -n "$PLUGIN_REGISTRY" ]; then
    # User explicitly set PLUGIN_REGISTRY, use it
    return
  fi

  # Try to detect timezone
  local TZ=""
  if command -v timedatectl &>/dev/null; then
    TZ=$(timedatectl show --property=Timezone --value 2>/dev/null)
  elif [ -f /etc/timezone ]; then
    TZ=$(cat /etc/timezone 2>/dev/null)
  fi

  # Select registry based on timezone
  case "$TZ" in
    Asia/Shanghai|Asia/Hong_Kong|Asia/Taipei|Asia/Chongqing|Asia/Urumqi|Asia/Harbin)
      # China and nearby regions
      PLUGIN_REGISTRY="higress-registry.cn-hangzhou.cr.aliyuncs.com"
      ;;
    Asia/Singapore|Asia/Jakarta|Asia/Bangkok|Asia/Kuala_Lumpur|Asia/Manila|Asia/Ho_Chi_Minh)
      # Southeast Asia
      PLUGIN_REGISTRY="higress-registry.ap-southeast-7.cr.aliyuncs.com"
      ;;
    America/*|US/*|Canada/*)
      # North America
      PLUGIN_REGISTRY="higress-registry.us-west-1.cr.aliyuncs.com"
      ;;
    *)
      # Default to Hangzhou for other regions
      PLUGIN_REGISTRY="$DEFAULT_PLUGIN_REGISTRY"
      ;;
  esac

  echo "Auto-detected timezone: $TZ"
  echo "Selected plugin registry: $PLUGIN_REGISTRY"
}

normalizePath() {
  if [ "$OS" != "windows" ]; then
    echo "$1"
    return
  fi
  echo "$(cygpath -m "$1")"
}

# Cross-platform sed in-place edit (macOS vs Linux)
sedInPlace() {
  if [ "$OS" == "darwin" ]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

parseArgs() {
  resetEnv

  POSITIONAL_ARGS=()

  COMMAND=""
  MODE="wizard"

  if [[ $1 != "-"* ]]; then
    COMMAND="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case $1 in
    -h | --help)
      outputUsage
      exit 0
      ;;
    --non-interactive | --batch)
      MODE="batch"
      shift
      ;;
    --http-port)
      GATEWAY_HTTP_PORT="$2"
      shift 2
      ;;
    --https-port)
      GATEWAY_HTTPS_PORT="$2"
      shift 2
      ;;
    --console-port)
      CONSOLE_PORT="$2"
      shift 2
      ;;
    --container-name)
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --image-repo)
      IMAGE_REPO="$2"
      shift 2
      ;;
    --image-tag)
      IMAGE_TAG="$2"
      shift 2
      ;;
    --data-folder)
      DATA_FOLDER="$2"
      ROOT="$2"
      shift 2
      ;;
    --auto-routing)
      ENABLE_AUTO_ROUTING="true"
      shift
      ;;
    --auto-routing-default-model)
      AUTO_ROUTING_DEFAULT_MODEL="$2"
      shift 2
      ;;
    # LLM Provider API Keys
    --dashscope-key)
      DASHSCOPE_API_KEY="$2"
      LLM_ENVS+=("DASHSCOPE_API_KEY")
      shift 2
      ;;
    --deepseek-key)
      DEEPSEEK_API_KEY="$2"
      LLM_ENVS+=("DEEPSEEK_API_KEY")
      shift 2
      ;;
    --moonshot-key)
      MOONSHOT_API_KEY="$2"
      LLM_ENVS+=("MOONSHOT_API_KEY")
      shift 2
      ;;
    --zhipuai-key)
      ZHIPUAI_API_KEY="$2"
      LLM_ENVS+=("ZHIPUAI_API_KEY")
      shift 2
      ;;
    --openai-key)
      OPENAI_API_KEY="$2"
      LLM_ENVS+=("OPENAI_API_KEY")
      shift 2
      ;;
    --openrouter-key)
      OPENROUTER_API_KEY="$2"
      LLM_ENVS+=("OPENROUTER_API_KEY")
      shift 2
      ;;
    --claude-key)
      CLAUDE_API_KEY="$2"
      LLM_ENVS+=("CLAUDE_API_KEY")
      shift 2
      ;;
    --claude-version)
      CLAUDE_VERSION="$2"
      LLM_ENVS+=("CLAUDE_VERSION")
      shift 2
      ;;
    --claude-code-key)
      CLAUDE_CODE_API_KEY="$2"
      LLM_ENVS+=("CLAUDE_CODE_API_KEY")
      shift 2
      ;;
    --gemini-key)
      GEMINI_API_KEY="$2"
      LLM_ENVS+=("GEMINI_API_KEY")
      shift 2
      ;;
    --groq-key)
      GROQ_API_KEY="$2"
      LLM_ENVS+=("GROQ_API_KEY")
      shift 2
      ;;
    --doubao-key)
      DOUBAO_API_KEY="$2"
      LLM_ENVS+=("DOUBAO_API_KEY")
      shift 2
      ;;
    --baichuan-key)
      BAICHUAN_API_KEY="$2"
      LLM_ENVS+=("BAICHUAN_API_KEY")
      shift 2
      ;;
    --yi-key)
      YI_API_KEY="$2"
      LLM_ENVS+=("YI_API_KEY")
      shift 2
      ;;
    --stepfun-key)
      STEPFUN_API_KEY="$2"
      LLM_ENVS+=("STEPFUN_API_KEY")
      shift 2
      ;;
    --minimax-key)
      MINIMAX_API_KEY="$2"
      LLM_ENVS+=("MINIMAX_API_KEY")
      shift 2
      ;;
    --cohere-key)
      COHERE_API_KEY="$2"
      LLM_ENVS+=("COHERE_API_KEY")
      shift 2
      ;;
    --mistral-key)
      MISTRAL_API_KEY="$2"
      LLM_ENVS+=("MISTRAL_API_KEY")
      shift 2
      ;;
    --github-key)
      GITHUB_API_KEY="$2"
      LLM_ENVS+=("GITHUB_API_KEY")
      shift 2
      ;;
    --fireworks-key)
      FIREWORKS_API_KEY="$2"
      LLM_ENVS+=("FIREWORKS_API_KEY")
      shift 2
      ;;
    --togetherai-key)
      TOGETHERAI_API_KEY="$2"
      LLM_ENVS+=("TOGETHERAI_API_KEY")
      shift 2
      ;;
    --grok-key)
      GROK_API_KEY="$2"
      LLM_ENVS+=("GROK_API_KEY")
      shift 2
      ;;
    # Model pattern configurations for all providers
    --dashscope-models)
      DASHSCOPE_MODELS="$2"
      LLM_ENVS+=("DASHSCOPE_MODELS")
      shift 2
      ;;
    --deepseek-models)
      DEEPSEEK_MODELS="$2"
      LLM_ENVS+=("DEEPSEEK_MODELS")
      shift 2
      ;;
    --moonshot-models)
      MOONSHOT_MODELS="$2"
      LLM_ENVS+=("MOONSHOT_MODELS")
      shift 2
      ;;
    --zhipuai-models)
      ZHIPUAI_MODELS="$2"
      LLM_ENVS+=("ZHIPUAI_MODELS")
      shift 2
      ;;
    --zhipuai-domain)
      ZHIPUAI_DOMAIN="$2"
      shift 2
      ;;
    --zhipuai-code-plan-mode)
      ZHIPUAI_CODE_PLAN_MODE="true"
      shift
      ;;
    --minimax-models)
      MINIMAX_MODELS="$2"
      LLM_ENVS+=("MINIMAX_MODELS")
      shift 2
      ;;
    --azure-models)
      AZURE_MODELS="$2"
      LLM_ENVS+=("AZURE_MODELS")
      shift 2
      ;;
    --bedrock-models)
      BEDROCK_MODELS="$2"
      LLM_ENVS+=("BEDROCK_MODELS")
      shift 2
      ;;
    --vertex-models)
      VERTEX_MODELS="$2"
      LLM_ENVS+=("VERTEX_MODELS")
      shift 2
      ;;
    --openai-models)
      OPENAI_MODELS="$2"
      LLM_ENVS+=("OPENAI_MODELS")
      shift 2
      ;;
    --openrouter-models)
      OPENROUTER_MODELS="$2"
      LLM_ENVS+=("OPENROUTER_MODELS")
      shift 2
      ;;
    --cloudflare-models)
      CLOUDFLARE_MODELS="$2"
      LLM_ENVS+=("CLOUDFLARE_MODELS")
      shift 2
      ;;
    --deepl-models)
      DEEPL_MODELS="$2"
      LLM_ENVS+=("DEEPL_MODELS")
      shift 2
      ;;
    --dify-models)
      DIFY_MODELS="$2"
      LLM_ENVS+=("DIFY_MODELS")
      shift 2
      ;;
    --fireworks-models)
      FIREWORKS_MODELS="$2"
      LLM_ENVS+=("FIREWORKS_MODELS")
      shift 2
      ;;
    --github-models)
      GITHUB_MODELS="$2"
      LLM_ENVS+=("GITHUB_MODELS")
      shift 2
      ;;
    --grok-models)
      GROK_MODELS="$2"
      LLM_ENVS+=("GROK_MODELS")
      shift 2
      ;;
    --groq-models)
      GROQ_MODELS="$2"
      LLM_ENVS+=("GROQ_MODELS")
      shift 2
      ;;
    --spark-models)
      SPARK_MODELS="$2"
      LLM_ENVS+=("SPARK_MODELS")
      shift 2
      ;;
    --hunyuan-models)
      HUNYUAN_MODELS="$2"
      LLM_ENVS+=("HUNYUAN_MODELS")
      shift 2
      ;;
    --togetherai-models)
      TOGETHERAI_MODELS="$2"
      LLM_ENVS+=("TOGETHERAI_MODELS")
      shift 2
      ;;
    --yi-models)
      YI_MODELS="$2"
      LLM_ENVS+=("YI_MODELS")
      shift 2
      ;;
    --ai360-models)
      AI360_MODELS="$2"
      LLM_ENVS+=("AI360_MODELS")
      shift 2
      ;;
    --baichuan-models)
      BAICHUAN_MODELS="$2"
      LLM_ENVS+=("BAICHUAN_MODELS")
      shift 2
      ;;
    --baidu-models)
      BAIDU_MODELS="$2"
      LLM_ENVS+=("BAIDU_MODELS")
      shift 2
      ;;
    --claude-models)
      CLAUDE_MODELS="$2"
      LLM_ENVS+=("CLAUDE_MODELS")
      shift 2
      ;;
    --cohere-models)
      COHERE_MODELS="$2"
      LLM_ENVS+=("COHERE_MODELS")
      shift 2
      ;;
    --doubao-models)
      DOUBAO_MODELS="$2"
      LLM_ENVS+=("DOUBAO_MODELS")
      shift 2
      ;;
    --gemini-models)
      GEMINI_MODELS="$2"
      LLM_ENVS+=("GEMINI_MODELS")
      shift 2
      ;;
    --mistral-models)
      MISTRAL_MODELS="$2"
      LLM_ENVS+=("MISTRAL_MODELS")
      shift 2
      ;;
    --ollama-models)
      OLLAMA_MODELS="$2"
      LLM_ENVS+=("OLLAMA_MODELS")
      shift 2
      ;;
    --stepfun-models)
      STEPFUN_MODELS="$2"
      LLM_ENVS+=("STEPFUN_MODELS")
      shift 2
      ;;
    # Route command options
    --pattern)
      ROUTE_PATTERN="$2"
      shift 2
      ;;
    --model)
      ROUTE_MODEL="$2"
      shift 2
      ;;
    --trigger)
      ROUTE_TRIGGER="$2"
      shift 2
      ;;
    --rule-id)
      ROUTE_RULE_ID="$2"
      shift 2
      ;;
    # Config command options
    --provider)
      CONFIG_PROVIDER="$2"
      shift 2
      ;;
    --key)
      CONFIG_KEY="$2"
      shift 2
      ;;
    -* | --*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift
      ;;
    esac
  done

  set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

  if [ -z "$COMMAND" ]; then
    COMMAND=$COMMAND_START
  fi
  if [[ ! ${KNOWN_COMMANDS[@]} =~ "$COMMAND" ]]; then
    echo "Unknown command: $COMMAND"
    exit 1
  fi
  
  # Parse route subcommand
  if [ "$COMMAND" == "$COMMAND_ROUTE" ]; then
    if [ ${#POSITIONAL_ARGS[@]} -gt 0 ]; then
      ROUTE_SUBCOMMAND="${POSITIONAL_ARGS[0]}"
    else
      ROUTE_SUBCOMMAND=""
    fi
    if [ -z "$ROUTE_SUBCOMMAND" ]; then
      echo "Route subcommand required: add, list, remove"
      exit 1
    fi
    if [[ ! ${KNOWN_ROUTE_SUBCOMMANDS[@]} =~ "$ROUTE_SUBCOMMAND" ]]; then
      echo "Unknown route subcommand: $ROUTE_SUBCOMMAND"
      echo "Available: add, list, remove"
      exit 1
    fi
  fi

  # Parse config subcommand
  if [ "$COMMAND" == "$COMMAND_CONFIG" ]; then
    if [ ${#POSITIONAL_ARGS[@]} -gt 0 ]; then
      CONFIG_SUBCOMMAND="${POSITIONAL_ARGS[0]}"
    else
      CONFIG_SUBCOMMAND=""
    fi
    if [ -z "$CONFIG_SUBCOMMAND" ]; then
      echo "Config subcommand required: add, list, remove"
      exit 1
    fi
    if [[ ! ${KNOWN_CONFIG_SUBCOMMANDS[@]} =~ "$CONFIG_SUBCOMMAND" ]]; then
      echo "Unknown config subcommand: $CONFIG_SUBCOMMAND"
      echo "Available: add, list, remove"
      exit 1
    fi
  fi
}

configure() {
  if [ "$MODE" == "wizard" ]; then
    runConfigWizard
  fi

  configureStorage
  writeConfiguration
}

resetEnv() {
  DATA_FOLDER="$ROOT"
  CONTAINER_NAME="${CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}"

  # Detect and set plugin registry first (before IMAGE_REPO)
  detectPluginRegistry
  PLUGIN_REGISTRY="${PLUGIN_REGISTRY:-$DEFAULT_PLUGIN_REGISTRY}"
  
  # Build IMAGE_REPO from PLUGIN_REGISTRY if not explicitly set
  if [ -z "$IMAGE_REPO" ]; then
    IMAGE_REPO="${PLUGIN_REGISTRY}/higress/all-in-one"
  fi
  IMAGE_TAG="${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"

  GATEWAY_HTTP_PORT="${GATEWAY_HTTP_PORT:-$DEFAULT_GATEWAY_HTTP_PORT}"
  GATEWAY_HTTPS_PORT="${GATEWAY_HTTPS_PORT:-$DEFAULT_GATEWAY_HTTPS_PORT}"
  CONSOLE_PORT="${CONSOLE_PORT:-$DEFAULT_CONSOLE_PORT}"

  LLM_ENVS=()
  
  # ========== Model Pattern Defaults (can be updated anytime) ==========
  # Top 10 commonly used providers
  : "${DASHSCOPE_MODELS:=qwen-*}"
  : "${DEEPSEEK_MODELS:=deepseek-*}"
  : "${MOONSHOT_MODELS:=moonshot-*,kimi-*}"
  : "${ZHIPUAI_MODELS:=GLM-*,glm-*}"
  : "${MINIMAX_MODELS:=abab-*,MiniMax-*,minimax-*}"
  : "${AZURE_MODELS:=gpt-*,o1-*,o3-*}"
  : "${BEDROCK_MODELS:=*}"
  : "${VERTEX_MODELS:=gemini-*}"
  : "${OPENAI_MODELS:=gpt-*,o1-*,o3-*}"
  : "${OPENROUTER_MODELS:=*}"
  
  # Other providers (alphabetically ordered)
  : "${YI_MODELS:=yi-*}"
  : "${AI360_MODELS:=360GPT-*}"
  : "${BAICHUAN_MODELS:=Baichuan*}"
  : "${BAIDU_MODELS:=ERNIE-*}"
  : "${CLAUDE_MODELS:=claude-*}"
  : "${CLOUDFLARE_MODELS:=*}"
  : "${COHERE_MODELS:=command*}"
  : "${DEEPL_MODELS:=*}"
  : "${DIFY_MODELS:=*}"
  : "${DOUBAO_MODELS:=doubao-*}"
  : "${FIREWORKS_MODELS:=*}"
  : "${GITHUB_MODELS:=*}"
  : "${GEMINI_MODELS:=gemini-*}"
  : "${GROK_MODELS:=grok-*}"
  : "${GROQ_MODELS:=*}"
  : "${MISTRAL_MODELS:=mistral-*,open-mistral-*}"
  : "${OLLAMA_MODELS:=llama*,codellama*}"
  : "${SPARK_MODELS:=*}"
  : "${STEPFUN_MODELS:=step-*}"
  : "${HUNYUAN_MODELS:=hunyuan-*}"
  : "${TOGETHERAI_MODELS:=*}"
}

# Load saved configuration from config file
loadSavedConfig() {
  local CONFIG_FILE="$ROOT/$CONFIG_FILENAME"
  if [ -f "$CONFIG_FILE" ]; then
    # Read ENABLE_AUTO_ROUTING and AUTO_ROUTING_DEFAULT_MODEL from config
    local saved_auto_routing=$(grep "^ENABLE_AUTO_ROUTING=" "$CONFIG_FILE" | cut -d'=' -f2)
    local saved_default_model=$(grep "^AUTO_ROUTING_DEFAULT_MODEL=" "$CONFIG_FILE" | cut -d'=' -f2)
    if [ -n "$saved_auto_routing" ]; then
      ENABLE_AUTO_ROUTING="$saved_auto_routing"
    fi
    if [ -n "$saved_default_model" ]; then
      AUTO_ROUTING_DEFAULT_MODEL="$saved_default_model"
    fi
  fi
}

# Configure auto-routing in model-router plugin (inside container)
configureAutoRouting() {
  if [ "$ENABLE_AUTO_ROUTING" != "true" ]; then
    return 0
  fi

  echo "Configuring auto-routing in model-router plugin..."

  local MODEL_ROUTER_FILE="$ROOT/wasmplugins/model-router.internal.yaml"
  local CONTAINER_MODEL_ROUTER_FILE="/data/wasmplugins/model-router.internal.yaml"

  # Wait for the file to be created (it's created when the container starts)
  local MAX_WAIT=30
  local WAIT_COUNT=0
  while [ ! -f "$MODEL_ROUTER_FILE" ] && [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
  done

  if [ ! -f "$MODEL_ROUTER_FILE" ]; then
    echo "Warning: Could not find model-router configuration file at $MODEL_ROUTER_FILE"
    echo "Auto-routing will be configured manually later."
    return 1
  fi

  $DOCKER_COMMAND exec -i -e DEFAULT_MODEL="$AUTO_ROUTING_DEFAULT_MODEL" -e MODEL_ROUTER_FILE="$CONTAINER_MODEL_ROUTER_FILE" "$CONTAINER_NAME" /bin/sh <<'EOF'
set -e
cp ${MODEL_ROUTER_FILE} ${MODEL_ROUTER_FILE}.backup
awk -v model="$DEFAULT_MODEL" '
  /modelToHeader: x-higress-llm-model/ {
    print
    print "    autoRouting:"
    print "      enable: true"
    print "      defaultModel: " model
    next
  }
  { print }
' ${MODEL_ROUTER_FILE} > /tmp/model-router.internal.yaml.tmp.$$
mv /tmp/model-router.internal.yaml.tmp.* ${MODEL_ROUTER_FILE}
EOF

  echo "✓ Auto-routing configured with default model: $AUTO_ROUTING_DEFAULT_MODEL"
  echo "  Configuration file: $MODEL_ROUTER_FILE"
}

# Configuration wizard
runConfigWizard() {
  echo "Provide a key for each LLM provider you want to enable, then press Enter."
  echo "If no key is provided and Enter is pressed, configuration for that provider will be skipped."

  echo

  # Provider order: Top 10 most commonly used providers first, then others alphabetically
  local providers=(
    # Top 10 commonly used providers (user-specified order)
    "Aliyun Dashscope (Qwen)|DASHSCOPE|configureDashscopeProvider"
    "DeepSeek|DEEPSEEK|configureDeepSeekProvider"
    "Moonshot (Kimi)|MOONSHOT|configureMoonshotProvider"
    "Zhipu AI|ZHIPUAI|configureZhipuAIProvider"
    "Claude Code|CLAUDE_CODE|configureClaudeCodeProvider"
    "Claude|CLAUDE|configureClaudeProvider"
    "Minimax|MINIMAX|configureMinimaxProvider"
    "Azure OpenAI|AZURE|configureAzureProvider"
    "AWS Bedrock|BEDROCK|configureBedrockProvider"
    "OpenAI|OPENAI|configureOpenAIProvider"
    "OpenRouter|OPENROUTER|configureOpenRouterProvider"
    # Other providers (alphabetically ordered)
    "01.AI (Yi)|YI|configureYiProvider"
    "360 Zhinao|AI360|configureAI360Provider"
    "Baichuan AI|BAICHUAN|configureBaichuanProvider"
    "Baidu AI Cloud|BAIDU|configureBaiduProvider"
    "Claude|CLAUDE|configureClaudeProvider"
    "Cloudflare Workers AI|CLOUDFLARE|configureCloudflareProvider"
    "Cohere|COHERE|configureCohereProvider"
    "DeepL|DEEPL|configureDeepLProvider"
    "Dify|DIFY|configureDifyProvider"
    "Doubao|DOUBAO|configureDoubaoProvider"
    "Fireworks AI|FIREWORKS|configureFireworksProvider"
    "Github Models|GITHUB|configureGitHubProvider"
    "Google Gemini|GEMINI|configureGeminiProvider"
    "Grok|GROK|configureGrokProvider"
    "Groq|GROQ|configureGroqProvider"
    "Mistral AI|MISTRAL|configureMistralProvider"
    "Ollama|OLLAMA|configureOllamaProvider"
    "iFlyTek Spark|SPARK|configureSparkProvider"
    "Stepfun|STEPFUN|configureStepfunProvider"
    "Tencent Hunyuan|HUNYUAN|configureHunyuanProvider"
    "Together AI|TOGETHERAI|configureTogetherAIProvider"
  )

  local selectedIndex=''
  while :; do
    declare -i i=0
    for provider in "${providers[@]}"; do
      IFS='|' read -ra segments <<<"$provider"
      local providerName=${segments[0]}
      local apiKeyVarName="${segments[1]}_API_KEY"
      local apiKeyConfiguredMarkName="${segments[1]}_CONFIGURED"
      local mark=""
      if [ -n "${!apiKeyVarName}" -o -n "${!apiKeyConfiguredMarkName}" ]; then
        mark="[Configured] "
      fi
      i+=1
      echo "${i}. ${mark}${providerName}"
    done
    read -r -u 3 -p "Please choose an LLM service provider to configure (1~$i, press Enter alone to break): " selectedIndex

    case $selectedIndex in
    '') break ;;  # Breaks the loop if the input is an empty string
    *[!0-9]*) echo "Please enter option number." ;;  # Handles invalid input where characters are non-numeric
    *)
      selectedIndex=$((selectedIndex))
      if [ $selectedIndex -gt $i ] || [ $selectedIndex -eq 0 ]; then
        echo "Incorrect option number."
      else
        local provider=${providers[$selectedIndex - 1]}
        IFS='|' read -ra segments <<<"$provider"
        local providerName=${segments[0]}
        local apiKeyVarName="${segments[1]}_API_KEY"
        local customConfigFunction="${segments[2]}"

        if [ -n "$customConfigFunction" ]; then
          $customConfigFunction
        else
          local token=""
          read -r -u 3 -p "→ Enter API Key for ${providerName}: " token
          IFS= read -r -d '' "${apiKeyVarName}" <<<"$token"
          LLM_ENVS+=("${apiKeyVarName}")
        fi
      fi
      ;;
    esac
  done

  echo

  # Validate only one between OpenAI and Azure OpenAI is configured
  if [ -n "${OPENAI_API_KEY}" ] && [ -n "${AZURE_API_KEY}" ]; then
    echo "Error: Can only configure either OpenAI or Azure OpenAI, not both"
    exit 1
  fi
}

configureAzureProvider() {
  for (( ; ; )); do
    read -r -u 3 -p "→ Enter Azure OpenAI service URL (Sample: https://YOUR_RESOURCE_NAME.openai.azure.com/openai/deployments/YOUR_DEPLOYMENT_NAME/chat/completions?api-version=2024-06-01): " AZURE_SERVICE_URL
    if [[ "$AZURE_SERVICE_URL" == "https://"* ]]; then
      break
    fi
    echo 'URL must start with "https://"'
  done
  read -r -u 3 -p "→ Enter API Key for Azure OpenAI: " AZURE_API_KEY
  LLM_ENVS+=("AZURE_SERVICE_URL" "AZURE_API_KEY")
  
  # Configure model pattern
  if [ -z "$AZURE_MODELS" ]; then
    echo "Enter model pattern for routing (regex, e.g., 'gpt-.*|o1-.*|o3-.*'):"
    read -r -u 3 -p "→ Model pattern (default: gpt-.*|o1-.*|o3-.*): " AZURE_MODELS
    if [ -z "$AZURE_MODELS" ]; then
      AZURE_MODELS="gpt-.*|o1-.*|o3-.*"
    fi
  fi
  LLM_ENVS+=("AZURE_MODELS")
}

configureOllamaProvider() {
  read -r -u 3 -p "→ Enter Ollama server host: " OLLAMA_SERVER_HOST
  readPortWithDefault "→ Enter Ollama server port (Default: 11434): " 11434
  OLLAMA_SERVER_PORT="$input"
  if [ -n "$OLLAMA_SERVER_HOST" ]; then
    # Mark as configured
    OLLAMA_CONFIGURED="placeholder"
  fi
  LLM_ENVS+=("OLLAMA_SERVER_HOST" "OLLAMA_SERVER_PORT")
  
  # Configure model pattern
  if [ -z "$OLLAMA_MODELS" ]; then
    echo "Enter model pattern for routing (regex, e.g., 'codellama.*|llama.*'):"
    read -r -u 3 -p "→ Model pattern (default: codellama.*|llama.*): " OLLAMA_MODELS
    if [ -z "$OLLAMA_MODELS" ]; then
      OLLAMA_MODELS="codellama.*|llama.*"
    fi
  fi
  LLM_ENVS+=("OLLAMA_MODELS")
}

configureClaudeProvider() {
  read -r -u 3 -p "→ Enter API Key for Claude (or press Enter to skip): " CLAUDE_API_KEY
  local DEFAULT_CLAUDE_VERSION="2023-06-01"
  readWithDefault "→ Enter API version for Claude (Default: $DEFAULT_CLAUDE_VERSION): " $DEFAULT_CLAUDE_VERSION
  CLAUDE_VERSION="$input"
  
  if [ -n "$CLAUDE_API_KEY" ]; then
    LLM_ENVS+=("CLAUDE_API_KEY" "CLAUDE_VERSION")
  fi
  
  # Ask if using Claude Code mode (OAuth token)
  local use_claude_code=""
  read -r -u 3 -p "→ Use Claude Code mode with OAuth token? (y/N): " use_claude_code
  if [[ "$use_claude_code" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Note: To obtain your Claude Code OAuth token, run this command:"
    echo "  claude setup-token"
    echo "Copy the token and paste it below."
    echo ""
    read -r -u 3 -p "→ Enter OAuth Token for Claude Code: " CLAUDE_CODE_API_KEY
    if [ -n "$CLAUDE_CODE_API_KEY" ]; then
      LLM_ENVS+=("CLAUDE_CODE_API_KEY")
    fi
  fi
  
  # Configure model pattern
  if [ -z "$CLAUDE_MODELS" ]; then
    echo "Enter model pattern for routing (prefix match, e.g., 'claude-'):"
    read -r -u 3 -p "→ Model pattern (default: claude-): " CLAUDE_MODELS
    if [ -z "$CLAUDE_MODELS" ]; then
      CLAUDE_MODELS="claude-"
    fi
  fi
  LLM_ENVS+=("CLAUDE_MODELS")
}

configureMinimaxProvider() {
  read -r -u 3 -p "→ Enter API Key for Minimax: " MINIMAX_API_KEY
  read -r -u 3 -p "→ Enter group ID for Minimax (only required when using ChatCompletion Pro): " MINIMAX_GROUP_ID
  LLM_ENVS+=("MINIMAX_API_KEY" "MINIMAX_GROUP_ID")
  
  # Configure model pattern
  if [ -z "$MINIMAX_MODELS" ]; then
    echo "Enter model pattern for routing (prefix match, e.g., 'abab'):"
    read -r -u 3 -p "→ Model pattern (default: abab): " MINIMAX_MODELS
    if [ -z "$MINIMAX_MODELS" ]; then
      MINIMAX_MODELS="abab"
    fi
  fi
  LLM_ENVS+=("MINIMAX_MODELS")
}

configureBedrockProvider() {
  echo "AWS Bedrock supports two authentication methods:"
  echo "  1. AWS Signature V4 (Access Key + Secret Key)"
  echo "  2. Bearer Token (API Token)"
  read -r -u 3 -p "→ Choose authentication method (1 or 2, default: 1): " BEDROCK_AUTH_METHOD
  if [ "$BEDROCK_AUTH_METHOD" == "2" ]; then
    read -r -u 3 -p "→ Enter AWS Bearer Token: " BEDROCK_API_KEY
    LLM_ENVS+=("BEDROCK_API_KEY")
    read -r -u 3 -p "→ Enter AWS Region (e.g., us-east-1): " BEDROCK_REGION
    if [ -n "$BEDROCK_API_KEY" ] && [ -n "$BEDROCK_REGION" ]; then
      BEDROCK_CONFIGURED="placeholder"
    fi
  else
    read -r -u 3 -p "→ Enter AWS Access Key: " BEDROCK_ACCESS_KEY
    read -r -u 3 -p "→ Enter AWS Secret Key: " BEDROCK_SECRET_KEY
    LLM_ENVS+=("BEDROCK_ACCESS_KEY" "BEDROCK_SECRET_KEY")
    read -r -u 3 -p "→ Enter AWS Region (e.g., us-east-1): " BEDROCK_REGION
    if [ -n "$BEDROCK_ACCESS_KEY" ] && [ -n "$BEDROCK_SECRET_KEY" ] && [ -n "$BEDROCK_REGION" ]; then
      BEDROCK_CONFIGURED="placeholder"
    fi
  fi
  LLM_ENVS+=("BEDROCK_REGION")
  
  # Configure model pattern
  if [ -z "$BEDROCK_MODELS" ]; then
    echo "Enter model pattern for routing (regex, e.g., 'claude-.*' for Claude models, '.*' for all):"
    read -r -u 3 -p "→ Model pattern (default: .*): " BEDROCK_MODELS
    if [ -z "$BEDROCK_MODELS" ]; then
      BEDROCK_MODELS=".*"
    fi
  fi
  LLM_ENVS+=("BEDROCK_MODELS")
}

configureVertexProvider() {
  echo "Google Vertex AI supports two authentication modes:"
  echo "  1. Standard Mode (Service Account JSON Key)"
  echo "  2. Express Mode (API Key only)"
  read -r -u 3 -p "→ Choose authentication mode (1 or 2, default: 1): " VERTEX_AUTH_MODE
  if [ "$VERTEX_AUTH_MODE" == "2" ]; then
    read -r -u 3 -p "→ Enter Vertex AI API Key: " VERTEX_API_KEY
    LLM_ENVS+=("VERTEX_API_KEY")
    read -r -u 3 -p "→ Enter Google Cloud Region (e.g., us-central1): " VERTEX_REGION
    read -r -u 3 -p "→ Enter Google Cloud Project ID: " VERTEX_PROJECT_ID
    if [ -n "$VERTEX_API_KEY" ] && [ -n "$VERTEX_REGION" ] && [ -n "$VERTEX_PROJECT_ID" ]; then
      VERTEX_CONFIGURED="placeholder"
    fi
  else
    read -r -u 3 -p "→ Enter path to Service Account JSON Key file: " VERTEX_AUTH_KEY_FILE
    if [ -n "$VERTEX_AUTH_KEY_FILE" ] && [ -f "$VERTEX_AUTH_KEY_FILE" ]; then
      # Read JSON file and compact it to a single line
      VERTEX_AUTH_KEY=$(cat "$VERTEX_AUTH_KEY_FILE" | tr -d '\n' | tr -s ' ')
    else
      echo "Warning: File not found or not specified. Please configure manually later."
      VERTEX_AUTH_KEY=""
    fi
    read -r -u 3 -p "→ Enter Vertex AI Auth Service Name: " VERTEX_AUTH_SERVICE_NAME
    LLM_ENVS+=("VERTEX_AUTH_KEY" "VERTEX_AUTH_SERVICE_NAME")
    read -r -u 3 -p "→ Enter Google Cloud Region (e.g., us-central1): " VERTEX_REGION
    read -r -u 3 -p "→ Enter Google Cloud Project ID: " VERTEX_PROJECT_ID
    if [ -n "$VERTEX_AUTH_KEY" ] && [ -n "$VERTEX_AUTH_SERVICE_NAME" ] && [ -n "$VERTEX_REGION" ] && [ -n "$VERTEX_PROJECT_ID" ]; then
      VERTEX_CONFIGURED="placeholder"
    fi
  fi
  LLM_ENVS+=("VERTEX_REGION" "VERTEX_PROJECT_ID")
  
  # Configure model pattern
  if [ -z "$VERTEX_MODELS" ]; then
    echo "Enter model pattern for routing (regex, e.g., 'gemini-.*' for Gemini models, '.*' for all):"
    read -r -u 3 -p "→ Model pattern (default: gemini-.*): " VERTEX_MODELS
    if [ -z "$VERTEX_MODELS" ]; then
      VERTEX_MODELS="gemini-.*"
    fi
  fi
  LLM_ENVS+=("VERTEX_MODELS")
}

configureCloudflareProvider() {
  read -r -u 3 -p "→ Enter API Token for Cloudflare Workers AI: " CLOUDFLARE_API_KEY
  read -r -u 3 -p "→ Enter Cloudflare Account ID: " CLOUDFLARE_ACCOUNT_ID
  if [ -n "$CLOUDFLARE_API_KEY" ] && [ -n "$CLOUDFLARE_ACCOUNT_ID" ]; then
    CLOUDFLARE_CONFIGURED="placeholder"
  fi
  LLM_ENVS+=("CLOUDFLARE_API_KEY" "CLOUDFLARE_ACCOUNT_ID")
  
  # Configure model pattern
  if [ -z "$CLOUDFLARE_MODELS" ]; then
    echo "Enter model pattern for routing (regex, e.g., '@cf/.*' for Cloudflare models, '.*' for all):"
    read -r -u 3 -p "→ Model pattern (default: .*): " CLOUDFLARE_MODELS
    if [ -z "$CLOUDFLARE_MODELS" ]; then
      CLOUDFLARE_MODELS=".*"
    fi
  fi
  LLM_ENVS+=("CLOUDFLARE_MODELS")
}

configureDeepLProvider() {
  read -r -u 3 -p "→ Enter API Key for DeepL: " DEEPL_API_KEY
  read -r -u 3 -p "→ Enter target language for DeepL (e.g., EN, ZH, JA): " DEEPL_TARGET_LANG
  if [ -n "$DEEPL_API_KEY" ] && [ -n "$DEEPL_TARGET_LANG" ]; then
    DEEPL_CONFIGURED="placeholder"
  fi
  LLM_ENVS+=("DEEPL_API_KEY" "DEEPL_TARGET_LANG")
  
  # Configure model pattern
  if [ -z "$DEEPL_MODELS" ]; then
    echo "Enter model pattern for routing (regex, e.g., 'deepl-.*', '.*' for all):"
    read -r -u 3 -p "→ Model pattern (default: .*): " DEEPL_MODELS
    if [ -z "$DEEPL_MODELS" ]; then
      DEEPL_MODELS=".*"
    fi
  fi
  LLM_ENVS+=("DEEPL_MODELS")
}

configureDifyProvider() {
  read -r -u 3 -p "→ Enter API Key for Dify: " DIFY_API_KEY
  read -r -u 3 -p "→ Enter Dify API URL (leave empty for cloud service): " DIFY_API_URL
  echo "Dify application types: Chat, Completion, Agent, Workflow"
  read -r -u 3 -p "→ Enter Dify bot type (default: Chat): " DIFY_BOT_TYPE
  if [ -z "$DIFY_BOT_TYPE" ]; then
    DIFY_BOT_TYPE="Chat"
  fi
  LLM_ENVS+=("DIFY_API_KEY" "DIFY_API_URL" "DIFY_BOT_TYPE")
  if [ "$DIFY_BOT_TYPE" == "Workflow" ]; then
    read -r -u 3 -p "→ Enter Dify input variable name: " DIFY_INPUT_VARIABLE
    read -r -u 3 -p "→ Enter Dify output variable name: " DIFY_OUTPUT_VARIABLE
    LLM_ENVS+=("DIFY_INPUT_VARIABLE" "DIFY_OUTPUT_VARIABLE")
  fi
  
  # Configure model pattern
  if [ -z "$DIFY_MODELS" ]; then
    echo "Enter model pattern for routing (regex, e.g., 'dify-.*', '.*' for all):"
    read -r -u 3 -p "→ Model pattern (default: .*): " DIFY_MODELS
    if [ -z "$DIFY_MODELS" ]; then
      DIFY_MODELS=".*"
    fi
  fi
  LLM_ENVS+=("DIFY_MODELS")
}

configureSparkProvider() {
  echo "Note: iFlyTek Spark API Key format is APIKey:APISecret"
  read -r -u 3 -p "→ Enter API Key for iFlyTek Spark: " SPARK_API_KEY
  read -r -u 3 -p "→ Enter API Secret for iFlyTek Spark: " SPARK_API_SECRET
  if [ -n "$SPARK_API_KEY" ] && [ -n "$SPARK_API_SECRET" ]; then
    SPARK_API_KEY="${SPARK_API_KEY}:${SPARK_API_SECRET}"
    SPARK_CONFIGURED="placeholder"
  fi
  LLM_ENVS+=("SPARK_API_KEY")
  
  # Configure model pattern
  if [ -z "$SPARK_MODELS" ]; then
    echo "Enter model pattern for routing (regex, e.g., 'spark-.*', '.*' for all):"
    read -r -u 3 -p "→ Model pattern (default: .*): " SPARK_MODELS
    if [ -z "$SPARK_MODELS" ]; then
      SPARK_MODELS=".*"
    fi
  fi
  LLM_ENVS+=("SPARK_MODELS")
}

configureHunyuanProvider() {
  read -r -u 3 -p "→ Enter Auth ID for Tencent Hunyuan: " HUNYUAN_AUTH_ID
  read -r -u 3 -p "→ Enter Auth Key for Tencent Hunyuan: " HUNYUAN_AUTH_KEY
  if [ -n "$HUNYUAN_AUTH_ID" ] && [ -n "$HUNYUAN_AUTH_KEY" ]; then
    HUNYUAN_CONFIGURED="placeholder"
  fi
  LLM_ENVS+=("HUNYUAN_AUTH_ID" "HUNYUAN_AUTH_KEY")
  
  # Configure model pattern
  if [ -z "$HUNYUAN_MODELS" ]; then
    echo "Enter model pattern for routing (regex, e.g., 'hunyuan-.*', '.*' for all):"
    read -r -u 3 -p "→ Model pattern (default: hunyuan-.*): " HUNYUAN_MODELS
    if [ -z "$HUNYUAN_MODELS" ]; then
      HUNYUAN_MODELS="hunyuan-.*"
    fi
  fi
  LLM_ENVS+=("HUNYUAN_MODELS")
}

configureOpenRouterProvider() {
  read -r -u 3 -p "→ Enter API Key for OpenRouter: " OPENROUTER_API_KEY
  LLM_ENVS+=("OPENROUTER_API_KEY")
  
  # Configure model pattern
  if [ -z "$OPENROUTER_MODELS" ]; then
    echo "Enter model pattern for routing (regex, '.*' for all models):"
    read -r -u 3 -p "→ Model pattern (default: .*): " OPENROUTER_MODELS
    if [ -z "$OPENROUTER_MODELS" ]; then
      OPENROUTER_MODELS=".*"
    fi
  fi
  LLM_ENVS+=("OPENROUTER_MODELS")
}

configureFireworksProvider() {
  read -r -u 3 -p "→ Enter API Key for Fireworks AI: " FIREWORKS_API_KEY
  LLM_ENVS+=("FIREWORKS_API_KEY")
  
  # Configure model pattern
  if [ -z "$FIREWORKS_MODELS" ]; then
    echo "Enter model pattern for routing (regex, '.*' for all models):"
    read -r -u 3 -p "→ Model pattern (default: .*): " FIREWORKS_MODELS
    if [ -z "$FIREWORKS_MODELS" ]; then
      FIREWORKS_MODELS=".*"
    fi
  fi
  LLM_ENVS+=("FIREWORKS_MODELS")
}

configureGitHubProvider() {
  read -r -u 3 -p "→ Enter API Key for GitHub Models: " GITHUB_API_KEY
  LLM_ENVS+=("GITHUB_API_KEY")
  
  # Configure model pattern
  if [ -z "$GITHUB_MODELS" ]; then
    echo "Enter model pattern for routing (regex, '.*' for all models):"
    read -r -u 3 -p "→ Model pattern (default: .*): " GITHUB_MODELS
    if [ -z "$GITHUB_MODELS" ]; then
      GITHUB_MODELS=".*"
    fi
  fi
  LLM_ENVS+=("GITHUB_MODELS")
}

configureGrokProvider() {
  read -r -u 3 -p "→ Enter API Key for Grok: " GROK_API_KEY
  LLM_ENVS+=("GROK_API_KEY")
  
  # Configure model pattern
  if [ -z "$GROK_MODELS" ]; then
    echo "Enter model pattern for routing (regex, e.g., 'grok-.*'):"
    read -r -u 3 -p "→ Model pattern (default: grok-.*): " GROK_MODELS
    if [ -z "$GROK_MODELS" ]; then
      GROK_MODELS="grok-.*"
    fi
  fi
  LLM_ENVS+=("GROK_MODELS")
}

configureGroqProvider() {
  read -r -u 3 -p "→ Enter API Key for Groq: " GROQ_API_KEY
  LLM_ENVS+=("GROQ_API_KEY")
  
  # Configure model pattern
  if [ -z "$GROQ_MODELS" ]; then
    echo "Enter model pattern for routing (regex, '.*' for all models):"
    read -r -u 3 -p "→ Model pattern (default: .*): " GROQ_MODELS
    if [ -z "$GROQ_MODELS" ]; then
      GROQ_MODELS=".*"
    fi
  fi
  LLM_ENVS+=("GROQ_MODELS")
}

configureTogetherAIProvider() {
  read -r -u 3 -p "→ Enter API Key for Together AI: " TOGETHERAI_API_KEY
  LLM_ENVS+=("TOGETHERAI_API_KEY")
  
  # Configure model pattern
  if [ -z "$TOGETHERAI_MODELS" ]; then
    echo "Enter model pattern for routing (regex, '.*' for all models):"
    read -r -u 3 -p "→ Model pattern (default: .*): " TOGETHERAI_MODELS
    if [ -z "$TOGETHERAI_MODELS" ]; then
      TOGETHERAI_MODELS=".*"
    fi
  fi
  LLM_ENVS+=("TOGETHERAI_MODELS")
}

# Simple provider configuration functions
configureDashscopeProvider() {
  read -r -u 3 -p "→ Enter API Key for Aliyun Dashscope (Qwen): " DASHSCOPE_API_KEY
  LLM_ENVS+=("DASHSCOPE_API_KEY")
  
  if [ -z "$DASHSCOPE_MODELS" ]; then
    echo "Enter model pattern for routing (prefix match, e.g., 'qwen'):"
    read -r -u 3 -p "→ Model pattern (default: qwen): " DASHSCOPE_MODELS
    if [ -z "$DASHSCOPE_MODELS" ]; then
      DASHSCOPE_MODELS="qwen"
    fi
  fi
  LLM_ENVS+=("DASHSCOPE_MODELS")
}

configureDeepSeekProvider() {
  read -r -u 3 -p "→ Enter API Key for DeepSeek: " DEEPSEEK_API_KEY
  LLM_ENVS+=("DEEPSEEK_API_KEY")
  
  if [ -z "$DEEPSEEK_MODELS" ]; then
    echo "Enter model pattern for routing (prefix match, e.g., 'deepseek'):"
    read -r -u 3 -p "→ Model pattern (default: deepseek): " DEEPSEEK_MODELS
    if [ -z "$DEEPSEEK_MODELS" ]; then
      DEEPSEEK_MODELS="deepseek"
    fi
  fi
  LLM_ENVS+=("DEEPSEEK_MODELS")
}

configureMoonshotProvider() {
  read -r -u 3 -p "→ Enter API Key for Moonshot (Kimi): " MOONSHOT_API_KEY
  LLM_ENVS+=("MOONSHOT_API_KEY")
  
  if [ -z "$MOONSHOT_MODELS" ]; then
    echo "Enter model pattern for routing (regex, e.g., 'moonshot-.*|kimi-.*'):"
    read -r -u 3 -p "→ Model pattern (default: moonshot-.*|kimi-.*): " MOONSHOT_MODELS
    if [ -z "$MOONSHOT_MODELS" ]; then
      MOONSHOT_MODELS="moonshot-.*|kimi-.*"
    fi
  fi
  LLM_ENVS+=("MOONSHOT_MODELS")
}

configureZhipuAIProvider() {
  read -r -u 3 -p "→ Enter API Key for Zhipu AI: " ZHIPUAI_API_KEY
  LLM_ENVS+=("ZHIPUAI_API_KEY")
  
  if [ -z "$ZHIPUAI_MODELS" ]; then
    echo "Enter model pattern for routing (prefix match, e.g., 'GLM-'):"
    read -r -u 3 -p "→ Model pattern (default: GLM-): " ZHIPUAI_MODELS
    if [ -z "$ZHIPUAI_MODELS" ]; then
      ZHIPUAI_MODELS="GLM-"
    fi
  fi
  LLM_ENVS+=("ZHIPUAI_MODELS")

  if [ -z "$ZHIPUAI_DOMAIN" ]; then
    echo "Choose domain (China: open.bigmodel.cn, International: api.z.ai):"
    read -r -u 3 -p "→ Domain (default: open.bigmodel.cn): " ZHIPUAI_DOMAIN
  fi

  if [ -z "$ZHIPUAI_CODE_PLAN_MODE" ]; then
    read -r -u 3 -p "→ Enable Code Plan Mode? (y/N): " ENABLE_CODE_PLAN
    if [[ "$ENABLE_CODE_PLAN" =~ ^[Yy] ]]; then
      ZHIPUAI_CODE_PLAN_MODE="true"
    fi
  fi
}

configureOpenAIProvider() {
  read -r -u 3 -p "→ Enter API Key for OpenAI: " OPENAI_API_KEY
  LLM_ENVS+=("OPENAI_API_KEY")
  
  if [ -z "$OPENAI_MODELS" ]; then
    echo "Enter model pattern for routing (regex, e.g., 'gpt-.*|o1-.*|o3-.*'):"
    read -r -u 3 -p "→ Model pattern (default: gpt-.*|o1-.*|o3-.*): " OPENAI_MODELS
    if [ -z "$OPENAI_MODELS" ]; then
      OPENAI_MODELS="gpt-.*|o1-.*|o3-.*"
    fi
  fi
  LLM_ENVS+=("OPENAI_MODELS")
}

configureYiProvider() {
  read -r -u 3 -p "→ Enter API Key for 01.AI (Yi): " YI_API_KEY
  LLM_ENVS+=("YI_API_KEY")
  
  if [ -z "$YI_MODELS" ]; then
    echo "Enter model pattern for routing (prefix match, e.g., 'yi-'):"
    read -r -u 3 -p "→ Model pattern (default: yi-): " YI_MODELS
    if [ -z "$YI_MODELS" ]; then
      YI_MODELS="yi-"
    fi
  fi
  LLM_ENVS+=("YI_MODELS")
}

configureAI360Provider() {
  read -r -u 3 -p "→ Enter API Key for 360 Zhinao: " AI360_API_KEY
  LLM_ENVS+=("AI360_API_KEY")
  
  if [ -z "$AI360_MODELS" ]; then
    echo "Enter model pattern for routing (prefix match, e.g., '360GPT'):"
    read -r -u 3 -p "→ Model pattern (default: 360GPT): " AI360_MODELS
    if [ -z "$AI360_MODELS" ]; then
      AI360_MODELS="360GPT"
    fi
  fi
  LLM_ENVS+=("AI360_MODELS")
}

configureBaichuanProvider() {
  read -r -u 3 -p "→ Enter API Key for Baichuan AI: " BAICHUAN_API_KEY
  LLM_ENVS+=("BAICHUAN_API_KEY")
  
  if [ -z "$BAICHUAN_MODELS" ]; then
    echo "Enter model pattern for routing (prefix match, e.g., 'Baichuan'):"
    read -r -u 3 -p "→ Model pattern (default: Baichuan): " BAICHUAN_MODELS
    if [ -z "$BAICHUAN_MODELS" ]; then
      BAICHUAN_MODELS="Baichuan"
    fi
  fi
  LLM_ENVS+=("BAICHUAN_MODELS")
}

configureBaiduProvider() {
  read -r -u 3 -p "→ Enter API Key for Baidu AI Cloud: " BAIDU_API_KEY
  LLM_ENVS+=("BAIDU_API_KEY")
  
  if [ -z "$BAIDU_MODELS" ]; then
    echo "Enter model pattern for routing (prefix match, e.g., 'ERNIE-'):"
    read -r -u 3 -p "→ Model pattern (default: ERNIE-): " BAIDU_MODELS
    if [ -z "$BAIDU_MODELS" ]; then
      BAIDU_MODELS="ERNIE-"
    fi
  fi
  LLM_ENVS+=("BAIDU_MODELS")
}

configureCohereProvider() {
  read -r -u 3 -p "→ Enter API Key for Cohere: " COHERE_API_KEY
  LLM_ENVS+=("COHERE_API_KEY")
  
  if [ -z "$COHERE_MODELS" ]; then
    echo "Enter model pattern for routing (regex, e.g., 'command|command-.*'):"
    read -r -u 3 -p "→ Model pattern (default: command|command-.*): " COHERE_MODELS
    if [ -z "$COHERE_MODELS" ]; then
      COHERE_MODELS="command|command-.*"
    fi
  fi
  LLM_ENVS+=("COHERE_MODELS")
}

configureDoubaoProvider() {
  read -r -u 3 -p "→ Enter API Key for Doubao: " DOUBAO_API_KEY
  LLM_ENVS+=("DOUBAO_API_KEY")
  
  if [ -z "$DOUBAO_MODELS" ]; then
    echo "Enter model pattern for routing (prefix match, e.g., 'doubao-'):"
    read -r -u 3 -p "→ Model pattern (default: doubao-): " DOUBAO_MODELS
    if [ -z "$DOUBAO_MODELS" ]; then
      DOUBAO_MODELS="doubao-"
    fi
  fi
  LLM_ENVS+=("DOUBAO_MODELS")
}

configureGeminiProvider() {
  read -r -u 3 -p "→ Enter API Key for Google Gemini: " GEMINI_API_KEY
  LLM_ENVS+=("GEMINI_API_KEY")
  
  if [ -z "$GEMINI_MODELS" ]; then
    echo "Enter model pattern for routing (prefix match, e.g., 'gemini-'):"
    read -r -u 3 -p "→ Model pattern (default: gemini-): " GEMINI_MODELS
    if [ -z "$GEMINI_MODELS" ]; then
      GEMINI_MODELS="gemini-"
    fi
  fi
  LLM_ENVS+=("GEMINI_MODELS")
}

configureMistralProvider() {
  read -r -u 3 -p "→ Enter API Key for Mistral AI: " MISTRAL_API_KEY
  LLM_ENVS+=("MISTRAL_API_KEY")
  
  if [ -z "$MISTRAL_MODELS" ]; then
    echo "Enter model pattern for routing (regex, e.g., 'open-mistral-.*|mistral-.*'):"
    read -r -u 3 -p "→ Model pattern (default: open-mistral-.*|mistral-.*): " MISTRAL_MODELS
    if [ -z "$MISTRAL_MODELS" ]; then
      MISTRAL_MODELS="open-mistral-.*|mistral-.*"
    fi
  fi
  LLM_ENVS+=("MISTRAL_MODELS")
}

configureStepfunProvider() {
  read -r -u 3 -p "→ Enter API Key for Stepfun: " STEPFUN_API_KEY
  LLM_ENVS+=("STEPFUN_API_KEY")
  
  if [ -z "$STEPFUN_MODELS" ]; then
    echo "Enter model pattern for routing (prefix match, e.g., 'step-'):"
    read -r -u 3 -p "→ Model pattern (default: step-): " STEPFUN_MODELS
    if [ -z "$STEPFUN_MODELS" ]; then
      STEPFUN_MODELS="step-"
    fi
  fi
  LLM_ENVS+=("STEPFUN_MODELS")
}

configureStorage() {
  if [ -d "$DATA_FOLDER" ]; then
    return 0
  fi
  mkdir -p "$DATA_FOLDER"
  if [ $? -ne 0 ]; then
    echo "Unable to create/access the data folder: $DATA_FOLDER"
    continue
  fi
}

readNonEmpty() {
  # $1 prompt
  while true; do
    read -r -u 3 -p "$1" input
    if [ -n "$input" ]; then
      break
    fi
  done
}

readWithDefault() {
  # $1 prompt
  # $2 default
  read -r -u 3 -p "$1" input
  if [ -z "$input" ]; then
    input="$2"
  fi
}

readPortWithDefault() {
  # $1 prompt
  # $2 default
  for (( ; ; )); do
    read -r -u 3 -p "$1" input
    if [ -z "$input" ]; then
      input="$2"
      break
    fi
    validatePort "$input" "Invalid port number." 0
    if [ $? -eq 0 ]; then
      break
    fi
  done
}

validatePort() {
  # $1 port
  # $2 error message
  # $3 exit when error if set to 1
  if [[ $1 =~ ^[0-9]+$ ]] && [ $1 -gt 0 ] && [ $1 -lt 65536 ]; then
    return 0
  fi
  echo "$2"
  if [ $3 -eq 1 ]; then
    exit -1
  else
    return -1
  fi
}

# ========== Build EXTRA_CONFIGS for all providers ==========
# These functions construct *_EXTRA_CONFIGS environment variables
# that are passed to ai-gateway.sh inside the container

buildZhipuAIExtraConfigs() {
  local configs=()
  if [ -n "$ZHIPUAI_DOMAIN" ]; then
    configs+=("zhipuDomain=\"$ZHIPUAI_DOMAIN\"")
  fi
  if [ "$ZHIPUAI_CODE_PLAN_MODE" = "true" ]; then
    configs+=("zhipuCodePlanMode=true")
  fi
  if [ ${#configs[@]} -gt 0 ]; then
    ZHIPUAI_EXTRA_CONFIGS=$(IFS=','; echo "${configs[*]}")
    LLM_ENVS+=("ZHIPUAI_EXTRA_CONFIGS")
  fi
}

buildMinimaxExtraConfigs() {
  local configs=()
  if [ -n "$MINIMAX_GROUP_ID" ]; then
    configs+=("minimaxGroupId=\"$MINIMAX_GROUP_ID\"")
  fi
  if [ ${#configs[@]} -gt 0 ]; then
    MINIMAX_EXTRA_CONFIGS=$(IFS=','; echo "${configs[*]}")
    LLM_ENVS+=("MINIMAX_EXTRA_CONFIGS")
  fi
}

buildAzureExtraConfigs() {
  local configs=()
  if [ -n "$AZURE_SERVICE_URL" ]; then
    configs+=("azureServiceUrl=$AZURE_SERVICE_URL")
  fi
  if [ ${#configs[@]} -gt 0 ]; then
    AZURE_EXTRA_CONFIGS=$(IFS=','; echo "${configs[*]}")
    LLM_ENVS+=("AZURE_EXTRA_CONFIGS")
  fi
}

buildBedrockExtraConfigs() {
  local configs=()
  if [ -n "$BEDROCK_REGION" ]; then
    configs+=("awsRegion=\"$BEDROCK_REGION\"")
  fi
  if [ -n "$BEDROCK_ACCESS_KEY" ]; then
    configs+=("awsAccessKey=\"$BEDROCK_ACCESS_KEY\"")
  fi
  if [ -n "$BEDROCK_SECRET_KEY" ]; then
    configs+=("awsSecretKey=\"$BEDROCK_SECRET_KEY\"")
  fi
  if [ ${#configs[@]} -gt 0 ]; then
    BEDROCK_EXTRA_CONFIGS=$(IFS=','; echo "${configs[*]}")
    LLM_ENVS+=("BEDROCK_EXTRA_CONFIGS")
  fi
}

buildVertexExtraConfigs() {
  local configs=()
  if [ -n "$VERTEX_PROJECT_ID" ]; then
    configs+=("vertexProjectId=\"$VERTEX_PROJECT_ID\"")
  fi
  if [ -n "$VERTEX_REGION" ]; then
    configs+=("vertexRegion=\"$VERTEX_REGION\"")
  fi
  if [ -n "$VERTEX_AUTH_KEY" ]; then
    configs+=("vertexAuthKey=\"$VERTEX_AUTH_KEY\"")
  fi
  if [ -n "$VERTEX_AUTH_SERVICE_NAME" ]; then
    configs+=("vertexAuthServiceName=\"$VERTEX_AUTH_SERVICE_NAME\"")
  fi
  if [ ${#configs[@]} -gt 0 ]; then
    VERTEX_EXTRA_CONFIGS=$(IFS=','; echo "${configs[*]}")
    LLM_ENVS+=("VERTEX_EXTRA_CONFIGS")
  fi
}

buildClaudeExtraConfigs() {
  local configs=()
  if [ -n "$CLAUDE_VERSION" ]; then
    configs+=("claudeVersion=\"$CLAUDE_VERSION\"")
  else
    configs+=("claudeVersion=\"2023-06-01\"")
  fi
  if [ -n "$CLAUDE_CODE_API_KEY" ]; then
    configs+=("claudeCodeMode=true")
  fi
  if [ ${#configs[@]} -gt 0 ]; then
    CLAUDE_EXTRA_CONFIGS=$(IFS=','; echo "${configs[*]}")
    LLM_ENVS+=("CLAUDE_EXTRA_CONFIGS")
  fi
}

buildCloudflareExtraConfigs() {
  local configs=()
  if [ -n "$CLOUDFLARE_ACCOUNT_ID" ]; then
    configs+=("cloudflareAccountId=\"$CLOUDFLARE_ACCOUNT_ID\"")
  fi
  if [ ${#configs[@]} -gt 0 ]; then
    CLOUDFLARE_EXTRA_CONFIGS=$(IFS=','; echo "${configs[*]}")
    LLM_ENVS+=("CLOUDFLARE_EXTRA_CONFIGS")
  fi
}

buildDeepLExtraConfigs() {
  local configs=()
  if [ -n "$DEEPL_TARGET_LANG" ]; then
    configs+=("targetLang=\"$DEEPL_TARGET_LANG\"")
  fi
  if [ ${#configs[@]} -gt 0 ]; then
    DEEPL_EXTRA_CONFIGS=$(IFS=','; echo "${configs[*]}")
    LLM_ENVS+=("DEEPL_EXTRA_CONFIGS")
  fi
}

buildDifyExtraConfigs() {
  local configs=()
  if [ -n "$DIFY_API_URL" ]; then
    configs+=("difyApiUrl=\"$DIFY_API_URL\"")
  fi
  if [ -n "$DIFY_BOT_TYPE" ]; then
    configs+=("botType=\"$DIFY_BOT_TYPE\"")
  fi
  if [ -n "$DIFY_INPUT_VARIABLE" ]; then
    configs+=("inputVariable=\"$DIFY_INPUT_VARIABLE\"")
  fi
  if [ -n "$DIFY_OUTPUT_VARIABLE" ]; then
    configs+=("outputVariable=\"$DIFY_OUTPUT_VARIABLE\"")
  fi
  if [ ${#configs[@]} -gt 0 ]; then
    DIFY_EXTRA_CONFIGS=$(IFS=','; echo "${configs[*]}")
    LLM_ENVS+=("DIFY_EXTRA_CONFIGS")
  fi
}

buildOllamaExtraConfigs() {
  local configs=()
  if [ -n "$OLLAMA_SERVER_HOST" ]; then
    configs+=("ollamaServerHost=\"$OLLAMA_SERVER_HOST\"")
  fi
  if [ -n "$OLLAMA_SERVER_PORT" ]; then
    configs+=("ollamaServerPort=$OLLAMA_SERVER_PORT")
  fi
  if [ ${#configs[@]} -gt 0 ]; then
    OLLAMA_EXTRA_CONFIGS=$(IFS=','; echo "${configs[*]}")
    LLM_ENVS+=("OLLAMA_EXTRA_CONFIGS")
  fi
}

buildHunyuanExtraConfigs() {
  local configs=()
  if [ -n "$HUNYUAN_AUTH_ID" ]; then
    configs+=("hunyuanAuthId=\"$HUNYUAN_AUTH_ID\"")
  fi
  if [ -n "$HUNYUAN_AUTH_KEY" ]; then
    configs+=("hunyuanAuthKey=\"$HUNYUAN_AUTH_KEY\"")
  fi
  if [ ${#configs[@]} -gt 0 ]; then
    HUNYUAN_EXTRA_CONFIGS=$(IFS=','; echo "${configs[*]}")
    LLM_ENVS+=("HUNYUAN_EXTRA_CONFIGS")
  fi
}

# Build all provider EXTRA_CONFIGS
buildAllExtraConfigs() {
  buildZhipuAIExtraConfigs
  buildMinimaxExtraConfigs
  buildAzureExtraConfigs
  buildBedrockExtraConfigs
  buildVertexExtraConfigs
  buildClaudeExtraConfigs
  buildCloudflareExtraConfigs
  buildDeepLExtraConfigs
  buildDifyExtraConfigs
  buildOllamaExtraConfigs
  buildHunyuanExtraConfigs
}

writeConfiguration() {
  # Build all provider extra configs before writing
  buildAllExtraConfigs
  
  local LLM_CONFIGS=""
  for env in "${LLM_ENVS[@]}"; do
    LLM_CONFIGS="$LLM_CONFIGS
${env}=${!env}"
  done
  
  # Add all *_MODELS variables to config
  for model_env in DASHSCOPE_MODELS DEEPSEEK_MODELS MOONSHOT_MODELS ZHIPUAI_MODELS \
                   MINIMAX_MODELS AZURE_MODELS BEDROCK_MODELS VERTEX_MODELS \
                   OPENAI_MODELS OPENROUTER_MODELS YI_MODELS AI360_MODELS \
                   BAICHUAN_MODELS BAIDU_MODELS CLAUDE_MODELS CLOUDFLARE_MODELS \
                   COHERE_MODELS DEEPL_MODELS DIFY_MODELS DOUBAO_MODELS \
                   FIREWORKS_MODELS GITHUB_MODELS GEMINI_MODELS GROK_MODELS \
                   GROQ_MODELS MISTRAL_MODELS OLLAMA_MODELS SPARK_MODELS \
                   STEPFUN_MODELS HUNYUAN_MODELS TOGETHERAI_MODELS; do
    if [ -n "${!model_env}" ]; then
      LLM_CONFIGS="$LLM_CONFIGS
${model_env}=${!model_env}"
    fi
  done

  # Save auto-routing configuration
  local AUTO_ROUTING_CONFIG=""
  if [ "$ENABLE_AUTO_ROUTING" == "true" ]; then
    AUTO_ROUTING_CONFIG="
ENABLE_AUTO_ROUTING=true
AUTO_ROUTING_DEFAULT_MODEL=${AUTO_ROUTING_DEFAULT_MODEL}"
  fi

  cat <<EOF >$DATA_FOLDER/$CONFIG_FILENAME
MODE=full
O11Y=on
CONFIG_TEMPLATE=ai-gateway
GATEWAY_HTTP_PORT=${GATEWAY_HTTP_PORT}
GATEWAY_HTTPS_PORT=${GATEWAY_HTTPS_PORT}
CONSOLE_PORT=${CONSOLE_PORT}
PLUGIN_REGISTRY=${PLUGIN_REGISTRY}
${LLM_CONFIGS}${AUTO_ROUTING_CONFIG}
EOF
}

outputUsage() {
  echo -n "Usage: $(basename -- "$0") [COMMAND] [OPTIONS...]"
  echo '

Commands:
  start                     Start the gateway (default)
  stop                      Stop the gateway
  delete                    Delete the gateway container
  route                     Manage auto-routing rules (see below)
  config                    Manage API key configuration (see below)

Route Subcommands:
  route add                 Add a new routing rule
  route list                List all routing rules
  route remove              Remove a routing rule by ID

Config Subcommands:
  config add                Add or update an API key
  config list               List all configured API keys
  config remove             Remove an API key

Options:
  -h, --help                Show this help message

Configuration Options (for non-interactive mode):
  --non-interactive         Run in batch mode without prompts
  --http-port PORT          Gateway HTTP port (default: 8080)
  --https-port PORT         Gateway HTTPS port (default: 8443)
  --console-port PORT       Console port (default: 8001)
  --container-name NAME     Container name (default: higress-ai-gateway)
  --image-repo REPO         Image repository
  --image-tag TAG           Image tag (default: latest)
  --data-folder PATH        Data folder path

Auto-Routing Options:
  --auto-routing            Enable auto-routing feature
  --auto-routing-default-model MODEL
                            Default model when no routing rule matches

Route Options (for route add/remove):
  --model MODEL             Target model for routing (required for add)
  --trigger PHRASE          Trigger phrase(s), separated by | (e.g., "深入思考|deep thinking")
  --pattern REGEX           Custom regex pattern (alternative to --trigger)
  --rule-id ID              Rule ID to remove (required for remove)

Config Options (for config add/remove):
  --provider PROVIDER       Provider name (dashscope, deepseek, moonshot, etc.)
  --key KEY                 API key to set (required for add)

LLM Provider API Keys:
  --dashscope-key KEY       Aliyun Dashscope (Qwen) API key
  --deepseek-key KEY        DeepSeek API key
  --moonshot-key KEY        Moonshot (Kimi) API key
  --zhipuai-key KEY         Zhipu AI API key
  --openai-key KEY          OpenAI API key
  --openrouter-key KEY      OpenRouter API key
  --claude-key KEY          Claude API key
  --claude-version VER      Claude API version (default: 2023-06-01)
  --claude-code-key KEY     Claude Code OAuth token (enables Code mode)
  --gemini-key KEY          Google Gemini API key
  --groq-key KEY            Groq API key
  --doubao-key KEY          Doubao API key
  --baichuan-key KEY        Baichuan AI API key
  --yi-key KEY              01.AI (Yi) API key
  --stepfun-key KEY         Stepfun API key
  --minimax-key KEY         Minimax API key
  --cohere-key KEY          Cohere API key
  --mistral-key KEY         Mistral AI API key
  --github-key KEY          Github Models API key
  --fireworks-key KEY       Fireworks AI API key
  --togetherai-key KEY      Together AI API key
  --grok-key KEY            Grok API key

Model Pattern Configurations:
  Configure which models each provider should handle. Supports flexible formats:
  
  Format 1: Wildcard prefix       model-*
    Example: --dashscope-models "qwen-*"
    Matches: qwen-max, qwen-plus, qwen-turbo, etc.
  
  Format 2: Exact model name      model-name
    Example: --openai-models "gpt-4-turbo"
    Matches: only gpt-4-turbo
  
  Format 3: Multiple wildcards    model1-*,model2-*
    Example: --moonshot-models "moonshot-*,kimi-*"
    Matches: moonshot-v1, kimi-2.5, etc.
  
  Format 4: Multiple exact names  model1,model2,model3
    Example: --openai-models "gpt-4-turbo,gpt-4o,gpt-4o-mini"
    Matches: only these three models
  
  Format 5: Mixed patterns        model-*,exact-name
    Example: --claude-models "claude-3-5-sonnet-*,claude-opus-4-20250514"
    Matches: claude-3-5-sonnet series + exact opus version
  
  Format 6: Match all             *
    Example: --openrouter-models "*"
    Matches: all models (catch-all provider)

  Available model pattern options:
  --dashscope-models PATTERN    Model pattern for Aliyun Dashscope
  --deepseek-models PATTERN     Model pattern for DeepSeek
  --moonshot-models PATTERN     Model pattern for Moonshot
  --zhipuai-models PATTERN      Model pattern for Zhipu AI
  --zhipuai-domain DOMAIN       Zhipu AI domain (default: open.bigmodel.cn, international: api.z.ai)
  --zhipuai-code-plan-mode      Enable Zhipu AI Code Plan mode
  --minimax-models PATTERN      Model pattern for Minimax
  --azure-models PATTERN        Model pattern for Azure OpenAI
  --bedrock-models PATTERN      Model pattern for AWS Bedrock
  --vertex-models PATTERN       Model pattern for Google Vertex AI
  --openai-models PATTERN       Model pattern for OpenAI
  --openrouter-models PATTERN   Model pattern for OpenRouter
  --yi-models PATTERN           Model pattern for 01.AI (Yi)
  --ai360-models PATTERN        Model pattern for 360 Zhinao
  --baichuan-models PATTERN     Model pattern for Baichuan AI
  --baidu-models PATTERN        Model pattern for Baidu AI Cloud
  --claude-models PATTERN       Model pattern for Claude (both standard and Code mode)
  --cloudflare-models PATTERN   Model pattern for Cloudflare Workers AI
  --cohere-models PATTERN       Model pattern for Cohere
  --deepl-models PATTERN        Model pattern for DeepL
  --dify-models PATTERN         Model pattern for Dify
  --doubao-models PATTERN       Model pattern for Doubao
  --fireworks-models PATTERN    Model pattern for Fireworks AI
  --github-models PATTERN       Model pattern for GitHub Models
  --gemini-models PATTERN       Model pattern for Google Gemini
  --grok-models PATTERN         Model pattern for Grok
  --groq-models PATTERN         Model pattern for Groq
  --mistral-models PATTERN      Model pattern for Mistral AI
  --ollama-models PATTERN       Model pattern for Ollama
  --spark-models PATTERN        Model pattern for iFlyTek Spark
  --stepfun-models PATTERN      Model pattern for Stepfun
  --hunyuan-models PATTERN      Model pattern for Tencent Hunyuan
  --togetherai-models PATTERN   Model pattern for Together AI

Examples:
  # Interactive wizard mode
  ./get-ai-gateway.sh

  # Non-interactive with specific providers
  ./get-ai-gateway.sh start --non-interactive \\
    --dashscope-key sk-xxx \\
    --openai-key sk-xxx \\
    --http-port 8080

  # Configure with model patterns (route specific models to specific providers)
  ./get-ai-gateway.sh start --non-interactive \\
    --openai-key sk-xxx --openai-models "gpt-4-*" \\
    --deepseek-key sk-xxx --deepseek-models "deepseek-*" \\
    --claude-key sk-xxx --claude-models "claude-3-5-sonnet-*"

  # Multi-provider setup with exact model names
  ./get-ai-gateway.sh start --non-interactive \\
    --openai-key sk-xxx --openai-models "gpt-4-turbo,gpt-4o" \\
    --claude-key sk-xxx --claude-models "claude-opus-4-20250514"

  # Use OpenRouter as catch-all for other models
  ./get-ai-gateway.sh start --non-interactive \\
    --openai-key sk-xxx --openai-models "gpt-4-*" \\
    --openrouter-key sk-xxx --openrouter-models "*"

  # Enable auto-routing
  ./get-ai-gateway.sh start --non-interactive \\
    --dashscope-key sk-xxx \\
    --auto-routing \\
    --auto-routing-default-model qwen-turbo

  # Add a routing rule (route to claude for complex problems)
  ./get-ai-gateway.sh route add \\
    --model claude-opus-4.5 \\
    --trigger "深入思考|deep thinking"

  # Add a routing rule for coding
  ./get-ai-gateway.sh route add \\
    --model qwen-coder \\
    --trigger "写代码|code:"

  # List all routing rules
  ./get-ai-gateway.sh route list

  # Remove a routing rule
  ./get-ai-gateway.sh route remove --rule-id 0

  # List all configured API keys
  ./get-ai-gateway.sh config list

  # Add or update an API key
  ./get-ai-gateway.sh config add --provider deepseek --key sk-xxx

  # Remove an API key
  ./get-ai-gateway.sh config remove --provider deepseek
'
}

outputWelcomeMessage() {
  echo '
 ___  ___  ___  ________  ________  _______   ________   ________
|\  \|\  \|\  \|\   ____\|\   __  \|\  ___ \ |\   ____\ |\   ____\
\ \  \\\  \ \  \ \  \___|\ \  \|\  \ \   __/|\ \  \___|_\ \  \___|_
 \ \   __  \ \  \ \  \  __\ \   _  _\ \  \_|/_\ \_____  \\ \_____  \
  \ \  \ \  \ \  \ \  \|\  \ \  \\  \\ \  \_|\ \|____|\  \\|____|\  \
   \ \__\ \__\ \__\ \_______\ \__\\ _\\ \_______\____\_\  \ ____\_\  \
    \|__|\|__|\|__|\|_______|\|__|\|__|\|_______|\_________\\_________\
                                                \|_________\|_________|
'
  echo "Higress AI Gateway is now running."

  echo
  echo "======================================================="
  echo "               Using Higress AI Gateway                "
  echo "======================================================="
  echo
  echo "Higress AI Gateway Data Plane endpoints:"
  echo "    HTTP  = http://localhost:$GATEWAY_HTTP_PORT"
  echo "    HTTPS = https://localhost:$GATEWAY_HTTPS_PORT"
  echo
  echo "Higress AI Gateway chat completion endpoint:"
  echo "    http://localhost:$GATEWAY_HTTP_PORT/v1/chat/completions"
  echo

  # Show auto-routing info if enabled (read from saved config)
  if [ "$ENABLE_AUTO_ROUTING" == "true" ]; then
    echo "======================================================="
    echo "                   Auto-Routing Mode                   "
    echo "======================================================="
    echo
    echo "Auto-routing is enabled! Use model 'higress/auto' to automatically"
    echo "route requests based on message content."
    echo
    echo "Default model: $AUTO_ROUTING_DEFAULT_MODEL"
    echo
    echo "Example with auto-routing:"
    echo
    echo "    curl 'http://localhost:$GATEWAY_HTTP_PORT/v1/chat/completions' \\"
    echo "      -H 'Content-Type: application/json' \\"
    echo "      -d '{"
    echo "        \"model\": \"higress/auto\","
    echo '        "messages": ['
    echo "          {"
    echo '            "role": "user",'
    echo '            "content": "深入思考 如何设计一个高并发系统？"'
    echo "          }"
    echo "        ]"
    echo "      }'"
    echo
  fi

  echo "You can try it with cURL directly:"
  echo
  echo "    curl 'http://localhost:$GATEWAY_HTTP_PORT/v1/chat/completions' \\"
  echo "      -H 'Content-Type: application/json' \\"
  echo "      -d '{"
  echo "        \"model\": \"qwen-turbo\","
  echo '        "messages": ['
  echo "          {"
  echo '            "role": "user",'
  echo '            "content": "Hello!"'
  echo "          }"
  echo "        ]"
  echo "      }'"

  echo
  echo "======================================================="
  echo "             Administer Higress AI Gateway             "
  echo "======================================================="
  echo
  echo "Higress Console URL (open with browser):"
  echo "   http://localhost:$CONSOLE_PORT"
  echo
  echo "Access logs directory:"
  echo "   $DATA_FOLDER/logs"
  echo
  echo "To stop the gateway run:"
  echo
  echo "  $DOCKER_COMMAND stop $CONTAINER_NAME"

  echo
  echo "Happy Higressing!"
}

tryAwake() {
  containerExists=$(docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format "{{.Names}}")

  if [ -z "$containerExists" ]; then
    return
  fi

  containerRunning=$(docker ps --filter "name=^/${CONTAINER_NAME}$" --filter "status=running" --format "{{.Names}}")

  if [ -z "$containerRunning" ]; then
    docker start "$CONTAINER_NAME"
    if [ $? -ne 0 ]; then
      exit -1
    fi
  fi

  # Load saved config to show auto-routing info correctly on restart
  loadSavedConfig
  
  outputWelcomeMessage
  exit 0
}

start() {
  echo "Starting Higress AI Gateway..."
  echo

  NORMALIZED_DATA_FOLDER_PATH="$(normalizePath "${DATA_FOLDER}")"
  NORMALIZED_CONFIG_FILE_PATH="$(normalizePath "${DATA_FOLDER}/${CONFIG_FILENAME}")"
  
  # Create log folder for mounting /var/log/proxy
  LOG_FOLDER="${DATA_FOLDER}/logs"
  mkdir -p "$LOG_FOLDER"
  NORMALIZED_LOG_FOLDER_PATH="$(normalizePath "${LOG_FOLDER}")"

  $DOCKER_COMMAND run --name "${CONTAINER_NAME}" -d \
    -p 127.0.0.1:$GATEWAY_HTTP_PORT:$GATEWAY_HTTP_PORT \
    -p 127.0.0.1:$GATEWAY_HTTPS_PORT:$GATEWAY_HTTPS_PORT \
    -p 127.0.0.1:$CONSOLE_PORT:$CONSOLE_PORT \
    --restart=always \
    --env-file "$NORMALIZED_CONFIG_FILE_PATH" \
    --mount "type=bind,source=$NORMALIZED_DATA_FOLDER_PATH,target=/data" \
    --mount "type=bind,source=$NORMALIZED_LOG_FOLDER_PATH,target=/var/log/proxy" "$IMAGE_REPO:$IMAGE_TAG" >/dev/null

  if [ $? -eq 0 ]; then
    # Wait a moment for the container to generate initial config files
    echo "Waiting for gateway to initialize..."
    sleep 5
    
    # Configure auto-routing if enabled
    configureAutoRouting
    
    outputWelcomeMessage
  fi
}

stop() {
  containerExists=$(docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format "{{.Names}}")

  if [ -z "$containerExists" ]; then
    echo "Higress AI Gateway not found."
    exit -1
  fi

  containerRunning=$(docker ps --filter "name=^/${CONTAINER_NAME}$" --filter "status=running" --format "{{.Names}}")

  if [ -z "$containerRunning" ]; then
    echo "Higress AI Gateway isn't running."
    exit 0
  fi

  echo "Stopping Higress AI Gateway..."
  echo

  $DOCKER_COMMAND stop $CONTAINER_NAME >/dev/null

  if [ $? -eq 0 ]; then
    echo "Thanks for using Higress AI Gateway."
  fi
}

delete() {
  containerExists=$(docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format "{{.Names}}")

  if [ -z "$containerExists" ]; then
    echo "Higress AI Gateway not found."
    exit 0
  fi

  containerRunning=$(docker ps --filter "name=^/${CONTAINER_NAME}$" --filter "status=running" --format "{{.Names}}")

  if [ -n "$containerRunning" ]; then
    echo "Higress AI Gateway is still running. Please stop it first."
    exit -1
  fi

  echo "Deleting Higress AI Gateway container..."
  echo

  $DOCKER_COMMAND rm $CONTAINER_NAME >/dev/null

  if [ $? -eq 0 ]; then
    echo "Thanks for using Higress AI Gateway."
  fi
}

# ============================================================================
# Route Command Functions
# ============================================================================

MODEL_ROUTER_CONFIG_PATH="/data/wasmplugins/model-router.internal.yaml"

# Generate a pattern from trigger phrase
generatePattern() {
  local trigger="$1"
  # Split by | and create regex pattern
  local patterns=""
  IFS='|' read -ra TRIGGERS <<< "$trigger"
  for t in "${TRIGGERS[@]}"; do
    t=$(echo "$t" | xargs)  # trim whitespace
    if [ -n "$patterns" ]; then
      patterns="$patterns|$t"
    else
      patterns="$t"
    fi
  done
  echo "(?i)^($patterns)"
}

# Check if container is running
checkContainer() {
  local running=$(docker ps --filter "name=^/${CONTAINER_NAME}$" --filter "status=running" --format "{{.Names}}")
  if [ -z "$running" ]; then
    echo "Error: Container '$CONTAINER_NAME' is not running."
    echo "Start it first with: $0 start"
    exit 1
  fi
}

# Route add: Add a new routing rule
routeAdd() {
  checkContainer
  
  if [ -z "$ROUTE_MODEL" ]; then
    echo "Error: --model is required"
    echo "Usage: $0 route add --model <model-name> --trigger <trigger-phrase>"
    echo "       $0 route add --model <model-name> --pattern <regex-pattern>"
    exit 1
  fi
  
  local pattern=""
  if [ -n "$ROUTE_PATTERN" ]; then
    pattern="$ROUTE_PATTERN"
  elif [ -n "$ROUTE_TRIGGER" ]; then
    pattern=$(generatePattern "$ROUTE_TRIGGER")
  else
    echo "Error: Either --trigger or --pattern is required"
    echo "Usage: $0 route add --model <model-name> --trigger <trigger-phrase>"
    echo "       $0 route add --model <model-name> --pattern <regex-pattern>"
    exit 1
  fi
  
  echo "Adding routing rule..."
  echo "  Pattern: $pattern"
  echo "  Model: $ROUTE_MODEL"
  
  # Copy config from container
  local temp_file=$(mktemp)
  docker cp "${CONTAINER_NAME}:${MODEL_ROUTER_CONFIG_PATH}" "$temp_file" 2>/dev/null
  
  if [ $? -ne 0 ]; then
    echo "Error: Could not read model-router configuration from container"
    rm -f "$temp_file"
    exit 1
  fi
  
  # Check if autoRouting section exists
  if ! grep -q "autoRouting:" "$temp_file"; then
    # Add autoRouting section
    sedInPlace '/modelToHeader:/a\    autoRouting:\n      enable: true\n      defaultModel: qwen-turbo\n      rules: []' "$temp_file"
  fi
  
  # Check if rules section exists under autoRouting
  if ! grep -q "rules:" "$temp_file"; then
    sedInPlace '/autoRouting:/a\      rules: []' "$temp_file"
  fi
  
  # Add new rule - escape special characters for sed
  local escaped_pattern=$(echo "$pattern" | sed 's/[&/\]/\\&/g')
  local escaped_model=$(echo "$ROUTE_MODEL" | sed 's/[&/\]/\\&/g')
  
  # Use Python for reliable YAML editing if available, otherwise use sed
  if command -v python3 &>/dev/null; then
    python3 << EOF
import yaml
import sys

with open('$temp_file', 'r') as f:
    config = yaml.safe_load(f)

if 'spec' not in config:
    config['spec'] = {}
if 'defaultConfig' not in config['spec']:
    config['spec']['defaultConfig'] = {}
if 'autoRouting' not in config['spec']['defaultConfig']:
    config['spec']['defaultConfig']['autoRouting'] = {
        'enable': True,
        'defaultModel': 'qwen-turbo',
        'rules': []
    }
if 'rules' not in config['spec']['defaultConfig']['autoRouting']:
    config['spec']['defaultConfig']['autoRouting']['rules'] = []

# Add new rule
config['spec']['defaultConfig']['autoRouting']['rules'].append({
    'pattern': '$pattern',
    'model': '$ROUTE_MODEL'
})

with open('$temp_file', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
EOF
  else
    # Fallback to sed (less reliable for YAML)
    sedInPlace "/rules:/a\\        - pattern: $escaped_pattern\n          model: $escaped_model" "$temp_file"
  fi
  
  # Copy back to container
  docker cp "$temp_file" "${CONTAINER_NAME}:${MODEL_ROUTER_CONFIG_PATH}"
  
  if [ $? -ne 0 ]; then
    echo "Error: Could not write model-router configuration to container"
    rm -f "$temp_file"
    exit 1
  fi
  
  # Touch file to trigger reload
  docker exec "$CONTAINER_NAME" touch "$MODEL_ROUTER_CONFIG_PATH"
  
  rm -f "$temp_file"
  
  echo
  echo "✅ Routing rule added successfully!"
  echo
  echo "Configuration has been hot-reloaded (no restart needed)."
  echo
  if [ -n "$ROUTE_TRIGGER" ]; then
    echo "Usage: Start your message with the trigger phrase to route to $ROUTE_MODEL"
    echo "  Example: $ROUTE_TRIGGER How to solve this problem?"
  else
    echo "Pattern: $pattern"
    echo "Model: $ROUTE_MODEL"
  fi
  echo
  echo "Note: Make sure to use model='higress/auto' in your API request."
}

# Route list: List all routing rules
routeList() {
  checkContainer
  
  echo "Current routing rules:"
  echo
  
  # Read config from container
  local config=$(docker exec "$CONTAINER_NAME" cat "$MODEL_ROUTER_CONFIG_PATH" 2>/dev/null)
  
  if [ $? -ne 0 ]; then
    echo "Error: Could not read model-router configuration from container"
    exit 1
  fi
  
  # Parse and display rules using Python if available
  if command -v python3 &>/dev/null; then
    echo "$config" | python3 << 'EOF'
import yaml
import sys

config = yaml.safe_load(sys.stdin.read())
auto_routing = config.get('spec', {}).get('defaultConfig', {}).get('autoRouting', {})

if not auto_routing.get('enable', False):
    print("Auto-routing is DISABLED")
    print()
    print("Enable it with: ./get-ai-gateway.sh start --auto-routing")
    sys.exit(0)

default_model = auto_routing.get('defaultModel', 'not set')
print(f"Default model: {default_model}")
print()

rules = auto_routing.get('rules', [])
if not rules:
    print("No routing rules configured.")
    print()
    print("Add a rule with:")
    print("  ./get-ai-gateway.sh route add --model <model> --trigger '<trigger-phrase>'")
else:
    print(f"{'ID':<4} {'Pattern':<40} {'Model':<20}")
    print("-" * 70)
    for i, rule in enumerate(rules):
        pattern = rule.get('pattern', 'N/A')[:38]
        model = rule.get('model', 'N/A')
        print(f"{i:<4} {pattern:<40} {model:<20}")
EOF
  else
    # Fallback: just show raw config section
    echo "$config" | grep -A 100 "autoRouting:" | head -50
  fi
}

# Route remove: Remove a routing rule by ID
routeRemove() {
  checkContainer
  
  if [ -z "$ROUTE_RULE_ID" ]; then
    echo "Error: --rule-id is required"
    echo "Usage: $0 route remove --rule-id <id>"
    echo
    echo "Use '$0 route list' to see rule IDs"
    exit 1
  fi
  
  echo "Removing routing rule ID: $ROUTE_RULE_ID"
  
  # Copy config from container
  local temp_file=$(mktemp)
  docker cp "${CONTAINER_NAME}:${MODEL_ROUTER_CONFIG_PATH}" "$temp_file" 2>/dev/null
  
  if [ $? -ne 0 ]; then
    echo "Error: Could not read model-router configuration from container"
    rm -f "$temp_file"
    exit 1
  fi
  
  # Remove rule using Python
  if command -v python3 &>/dev/null; then
    python3 << EOF
import yaml
import sys

with open('$temp_file', 'r') as f:
    config = yaml.safe_load(f)

rules = config.get('spec', {}).get('defaultConfig', {}).get('autoRouting', {}).get('rules', [])

rule_id = int('$ROUTE_RULE_ID')
if rule_id < 0 or rule_id >= len(rules):
    print(f"Error: Rule ID {rule_id} not found. Use 'route list' to see available rules.")
    sys.exit(1)

removed = rules.pop(rule_id)
print(f"Removed rule: pattern='{removed.get('pattern')}', model='{removed.get('model')}'")

with open('$temp_file', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
EOF
    
    if [ $? -ne 0 ]; then
      rm -f "$temp_file"
      exit 1
    fi
  else
    echo "Error: Python3 is required for removing rules"
    rm -f "$temp_file"
    exit 1
  fi
  
  # Copy back to container
  docker cp "$temp_file" "${CONTAINER_NAME}:${MODEL_ROUTER_CONFIG_PATH}"
  
  # Touch file to trigger reload
  docker exec "$CONTAINER_NAME" touch "$MODEL_ROUTER_CONFIG_PATH"
  
  rm -f "$temp_file"
  
  echo
  echo "✅ Routing rule removed successfully!"
  echo "Configuration has been hot-reloaded."
}

# Route command dispatcher
route() {
  case "$ROUTE_SUBCOMMAND" in
  "$ROUTE_ADD")
    routeAdd
    ;;
  "$ROUTE_LIST")
    routeList
    ;;
  "$ROUTE_REMOVE")
    routeRemove
    ;;
  esac
}

# ============================================================================
# Config Command Functions
# ============================================================================

AI_PROXY_CONFIG_PATH="/data/wasmplugins/ai-proxy.internal.yaml"

# Get provider name from environment variable name
getProviderName() {
  local env_var="$1"
  case "$env_var" in
    DASHSCOPE_API_KEY) echo "Aliyun Dashscope (Qwen)" ;;
    DEEPSEEK_API_KEY) echo "DeepSeek" ;;
    MOONSHOT_API_KEY) echo "Moonshot (Kimi)" ;;
    ZHIPUAI_API_KEY) echo "Zhipu AI" ;;
    OPENAI_API_KEY) echo "OpenAI" ;;
    OPENROUTER_API_KEY) echo "OpenRouter" ;;
    CLAUDE_API_KEY) echo "Claude" ;;
    GEMINI_API_KEY) echo "Google Gemini" ;;
    GROQ_API_KEY) echo "Groq" ;;
    DOUBAO_API_KEY) echo "Doubao" ;;
    BAICHUAN_API_KEY) echo "Baichuan AI" ;;
    YI_API_KEY) echo "01.AI (Yi)" ;;
    STEPFUN_API_KEY) echo "Stepfun" ;;
    MINIMAX_API_KEY) echo "Minimax" ;;
    COHERE_API_KEY) echo "Cohere" ;;
    MISTRAL_API_KEY) echo "Mistral AI" ;;
    GITHUB_API_KEY) echo "Github Models" ;;
    FIREWORKS_API_KEY) echo "Fireworks AI" ;;
    TOGETHERAI_API_KEY) echo "Together AI" ;;
    GROK_API_KEY) echo "Grok" ;;
    *) echo "Unknown ($env_var)" ;;
  esac
}

# Get environment variable name from provider shorthand
getEnvVarName() {
  local provider="$1"
  case "$provider" in
    dashscope|qwen) echo "DASHSCOPE_API_KEY" ;;
    deepseek) echo "DEEPSEEK_API_KEY" ;;
    moonshot|kimi) echo "MOONSHOT_API_KEY" ;;
    zhipuai|zhipu) echo "ZHIPUAI_API_KEY" ;;
    openai) echo "OPENAI_API_KEY" ;;
    openrouter) echo "OPENROUTER_API_KEY" ;;
    claude) echo "CLAUDE_API_KEY" ;;
    gemini) echo "GEMINI_API_KEY" ;;
    groq) echo "GROQ_API_KEY" ;;
    doubao) echo "DOUBAO_API_KEY" ;;
    baichuan) echo "BAICHUAN_API_KEY" ;;
    yi) echo "YI_API_KEY" ;;
    stepfun) echo "STEPFUN_API_KEY" ;;
    minimax) echo "MINIMAX_API_KEY" ;;
    cohere) echo "COHERE_API_KEY" ;;
    mistral) echo "MISTRAL_API_KEY" ;;
    github) echo "GITHUB_API_KEY" ;;
    fireworks) echo "FIREWORKS_API_KEY" ;;
    togetherai|together) echo "TOGETHERAI_API_KEY" ;;
    grok) echo "GROK_API_KEY" ;;
    *) echo "" ;;
  esac
}

# Get provider ID used in ai-proxy config from provider shorthand
getProviderId() {
  local provider="$1"
  case "$provider" in
    dashscope|qwen) echo "aliyun" ;;
    deepseek) echo "deepseek" ;;
    moonshot|kimi) echo "moonshot" ;;
    zhipuai|zhipu) echo "zhipuai" ;;
    openai) echo "openai" ;;
    openrouter) echo "openrouter" ;;
    claude) echo "claude" ;;
    gemini) echo "gemini" ;;
    groq) echo "groq" ;;
    doubao) echo "doubao" ;;
    baichuan) echo "baichuan" ;;
    yi) echo "yi" ;;
    stepfun) echo "stepfun" ;;
    minimax) echo "minimax" ;;
    cohere) echo "cohere" ;;
    mistral) echo "mistral" ;;
    github) echo "github" ;;
    fireworks) echo "fireworks" ;;
    togetherai|together) echo "togetherai" ;;
    grok) echo "grok" ;;
    *) echo "" ;;
  esac
}

# Mask API key for display
maskApiKey() {
  local key="$1"
  if [ -z "$key" ]; then
    echo "<not set>"
    return
  fi
  local len=${#key}
  if [ $len -le 8 ]; then
    echo "${key:0:2}***"
  else
    echo "${key:0:4}***${key: -4}"
  fi
}

# Config list: List all configured API keys
configList() {
  local config_file="$ROOT/$CONFIG_FILENAME"
  local container_running=$(docker ps --filter "name=^/${CONTAINER_NAME}$" --filter "status=running" --format "{{.Names}}")

  if [ -z "$container_running" ]; then
    echo "Error: Container '$CONTAINER_NAME' is not running."
    echo "Start it first with: $0 start"
    exit 1
  fi

  echo "Current LLM Provider API Keys:"
  echo

  # List of known API key environment variables
  local api_keys=(
    "DASHSCOPE_API_KEY"
    "DEEPSEEK_API_KEY"
    "MOONSHOT_API_KEY"
    "ZHIPUAI_API_KEY"
    "OPENAI_API_KEY"
    "OPENROUTER_API_KEY"
    "CLAUDE_API_KEY"
    "GEMINI_API_KEY"
    "GROQ_API_KEY"
    "DOUBAO_API_KEY"
    "BAICHUAN_API_KEY"
    "YI_API_KEY"
    "STEPFUN_API_KEY"
    "MINIMAX_API_KEY"
    "COHERE_API_KEY"
    "MISTRAL_API_KEY"
    "GITHUB_API_KEY"
    "FIREWORKS_API_KEY"
    "TOGETHERAI_API_KEY"
    "GROK_API_KEY"
  )

  local found=0
  for env_var in "${api_keys[@]}"; do
    local value=$(grep "^${env_var}=" "$config_file" 2>/dev/null | cut -d'=' -f2-)
    if [ -n "$value" ]; then
      local provider_name=$(getProviderName "$env_var")
      local masked=$(maskApiKey "$value")
      printf "  %-25s %s\n" "$provider_name:" "$masked"
      found=1
    fi
  done

  if [ $found -eq 0 ]; then
    echo "  No API keys configured."
    echo
    echo "Add an API key with:"
    echo "  $0 config add --provider <provider> --key <api-key>"
  else
    echo
    echo "Update an API key with:"
    echo "  $0 config add --provider <provider> --key <new-api-key>"
    echo
    echo "Remove an API key with:"
    echo "  $0 config remove --provider <provider>"
  fi
}

# Config add: Add or update an API key
configAdd() {
  checkContainer

  if [ -z "$CONFIG_PROVIDER" ]; then
    echo "Error: --provider is required"
    echo
    echo "Supported providers:"
    echo "  dashscope, deepseek, moonshot, zhipuai, openai, openrouter,"
    echo "  claude, gemini, groq, doubao, baichuan, yi, stepfun, minimax,"
    echo "  cohere, mistral, github, fireworks, togetherai, grok"
    echo
    echo "Usage: $0 config add --provider <provider> --key <api-key>"
    exit 1
  fi

  if [ -z "$CONFIG_KEY" ]; then
    echo "Error: --key is required"
    echo "Usage: $0 config add --provider <provider> --key <api-key>"
    exit 1
  fi

  local config_file="$ROOT/$CONFIG_FILENAME"
  if [ ! -f "$config_file" ]; then
    echo "Error: Configuration file not found: $config_file"
    echo "Please start the gateway first with: $0 start"
    exit 1
  fi

  local env_var=$(getEnvVarName "$CONFIG_PROVIDER")
  if [ -z "$env_var" ]; then
    echo "Error: Unknown provider: $CONFIG_PROVIDER"
    echo
    echo "Supported providers:"
    echo "  dashscope, deepseek, moonshot, zhipuai, openai, openrouter,"
    echo "  claude, gemini, groq, doubao, baichuan, yi, stepfun, minimax,"
    echo "  cohere, mistral, github, fireworks, togetherai, grok"
    exit 1
  fi

  local provider_name=$(getProviderName "$env_var")
  local provider_id=$(getProviderId "$CONFIG_PROVIDER")

  # Update config file on host
  if grep -q "^${env_var}=" "$config_file"; then
    echo "Updating API key for $provider_name in config file..."
    sedInPlace "/^${env_var}=/c\\${env_var}=${CONFIG_KEY}" "$config_file"
  else
    echo "Adding API key for $provider_name to config file..."
    echo "${env_var}=${CONFIG_KEY}" >> "$config_file"
  fi

  # Update ai-proxy config in container
  echo "Updating AI Gateway configuration..."
  local temp_file=$(mktemp)
  docker cp "${CONTAINER_NAME}:${AI_PROXY_CONFIG_PATH}" "$temp_file" 2>/dev/null

  if [ $? -ne 0 ]; then
    echo "Error: Could not read ai-proxy configuration from container"
    rm -f "$temp_file"
    exit 1
  fi

  # Use Python to update the API key
  if command -v python3 &>/dev/null; then
    python3 << EOF
import yaml
import sys

with open('$temp_file', 'r') as f:
    config = yaml.safe_load(f)

# Update or add the provider's API key
if 'spec' not in config:
    config['spec'] = {}
if 'defaultConfig' not in config['spec']:
    config['spec']['defaultConfig'] = {}

default_config = config['spec']['defaultConfig']
if 'providers' not in default_config:
    default_config['providers'] = []

# Find the provider and update its API key
found = False
for provider in default_config['providers']:
    if provider.get('id') == '$provider_id':
        if 'apiTokens' not in provider:
            provider['apiTokens'] = []
        # Update the first token
        if len(provider['apiTokens']) > 0:
            provider['apiTokens'][0] = '$CONFIG_KEY'
        else:
            provider['apiTokens'] = ['$CONFIG_KEY']
        found = True
        break

if not found:
    # Provider not found, add it
    default_config['providers'].append({
        'id': '$provider_id',
        'apiTokens': ['$CONFIG_KEY']
    })

with open('$temp_file', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
EOF
  else
    echo "Error: Python3 is required for updating API keys"
    rm -f "$temp_file"
    exit 1
  fi

  # Copy updated config back to container
  docker cp "$temp_file" "${CONTAINER_NAME}:${AI_PROXY_CONFIG_PATH}"

  if [ $? -ne 0 ]; then
    echo "Error: Could not write ai-proxy configuration to container"
    rm -f "$temp_file"
    exit 1
  fi

  # Touch file to trigger reload
  docker exec "$CONTAINER_NAME" touch "$AI_PROXY_CONFIG_PATH"

  rm -f "$temp_file"

  echo
  echo "✅ API key updated successfully!"
  echo
  echo "Provider: $provider_name"
  echo "Key: $(maskApiKey "$CONFIG_KEY")"
  echo
  echo "Configuration has been hot-reloaded (no restart needed)."
}

# Config remove: Remove an API key
configRemove() {
  checkContainer

  if [ -z "$CONFIG_PROVIDER" ]; then
    echo "Error: --provider is required"
    echo "Usage: $0 config remove --provider <provider>"
    exit 1
  fi

  local config_file="$ROOT/$CONFIG_FILENAME"
  if [ ! -f "$config_file" ]; then
    echo "Error: Configuration file not found: $config_file"
    echo "Please start the gateway first with: $0 start"
    exit 1
  fi

  local env_var=$(getEnvVarName "$CONFIG_PROVIDER")
  if [ -z "$env_var" ]; then
    echo "Error: Unknown provider: $CONFIG_PROVIDER"
    echo
    echo "Supported providers:"
    echo "  dashscope, deepseek, moonshot, zhipuai, openai, openrouter,"
    echo "  claude, gemini, groq, doubao, baichuan, yi, stepfun, minimax,"
    echo "  cohere, mistral, github, fireworks, togetherai, grok"
    exit 1
  fi

  local provider_name=$(getProviderName "$env_var")
  local provider_id=$(getProviderId "$CONFIG_PROVIDER")

  # Check if the key exists in config file
  if ! grep -q "^${env_var}=" "$config_file"; then
    echo "Error: No API key configured for $provider_name"
    echo
    echo "Current configuration:"
    echo "  $0 config list"
    exit 1
  fi

  # Remove from config file
  sedInPlace "/^${env_var}=/d" "$config_file"

  # Update ai-proxy config in container
  echo "Updating AI Gateway configuration..."
  local temp_file=$(mktemp)
  docker cp "${CONTAINER_NAME}:${AI_PROXY_CONFIG_PATH}" "$temp_file" 2>/dev/null

  if [ $? -ne 0 ]; then
    echo "Error: Could not read ai-proxy configuration from container"
    rm -f "$temp_file"
    exit 1
  fi

  # Use Python to remove the provider
  if command -v python3 &>/dev/null; then
    python3 << EOF
import yaml
import sys

with open('$temp_file', 'r') as f:
    config = yaml.safe_load(f)

# Remove the provider from the list
if 'spec' in config and 'defaultConfig' in config['spec']:
    default_config = config['spec']['defaultConfig']
    if 'providers' in default_config:
        default_config['providers'] = [
            p for p in default_config['providers']
            if p.get('id') != '$provider_id'
        ]

with open('$temp_file', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
EOF
  else
    echo "Error: Python3 is required for removing API keys"
    rm -f "$temp_file"
    exit 1
  fi

  # Copy updated config back to container
  docker cp "$temp_file" "${CONTAINER_NAME}:${AI_PROXY_CONFIG_PATH}"

  if [ $? -ne 0 ]; then
    echo "Error: Could not write ai-proxy configuration to container"
    rm -f "$temp_file"
    exit 1
  fi

  # Touch file to trigger reload
  docker exec "$CONTAINER_NAME" touch "$AI_PROXY_CONFIG_PATH"

  rm -f "$temp_file"

  echo
  echo "✅ API key removed successfully!"
  echo
  echo "Provider: $provider_name"
  echo
  echo "Configuration has been hot-reloaded (no restart needed)."
}

# Config command dispatcher
config() {
  case "$CONFIG_SUBCOMMAND" in
  "$CONFIG_ADD")
    configAdd
    ;;
  "$CONFIG_LIST")
    configList
    ;;
  "$CONFIG_REMOVE")
    configRemove
    ;;
  esac
}

# ============================================================================
# Main
# ============================================================================

initArch
initOS
parseArgs "$@"
case $COMMAND in
"$COMMAND_START")
  tryAwake
  if [ ! -f "$CONFIGURED_MARK" ]; then
    configure
    touch "$CONFIGURED_MARK"
  fi
  start
  ;;
"$COMMAND_STOP")
  stop
  ;;
"$COMMAND_DELETE")
  delete
  ;;
"$COMMAND_ROUTE")
  route
  ;;
"$COMMAND_CONFIG")
  config
  ;;
esac
