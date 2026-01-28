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
DEFAULT_IMAGE_TAG=latest
DEFAULT_GATEWAY_HTTP_PORT=8080
DEFAULT_GATEWAY_HTTPS_PORT=8443
DEFAULT_CONSOLE_PORT=8001

CONFIG_FILENAME="default.cfg"

COMMAND_START="start"
COMMAND_STOP="stop"
COMMAND_DELETE="delete"
KNOWN_COMMANDS=($COMMAND_START, $COMMAND_STOP, $COMMAND_DELETE)

cd "$(dirname -- "$0")"
ROOT="$(pwd -P)/higress"
cd - >/dev/null

CONFIGURED_MARK="$ROOT/.configured"

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

normalizePath() {
  if [ "$OS" != "windows" ]; then
    echo "$1"
    return
  fi
  echo "$(cygpath -m "$1")"
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

  IMAGE_REPO="${IMAGE_REPO:-$DEFAULT_IMAGE_REPO}"
  IMAGE_TAG="${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"

  GATEWAY_HTTP_PORT="${GATEWAY_HTTP_PORT:-$DEFAULT_GATEWAY_HTTP_PORT}"
  GATEWAY_HTTPS_PORT="${GATEWAY_HTTPS_PORT:-$DEFAULT_GATEWAY_HTTPS_PORT}"
  CONSOLE_PORT="${CONSOLE_PORT:-$DEFAULT_CONSOLE_PORT}"

  LLM_ENVS=()
}

# Configuration wizard
runConfigWizard() {
  echo "Provide a key for each LLM provider you want to enable, then press Enter."
  echo "If no key is provided and Enter is pressed, configuration for that provider will be skipped."

  echo

  # Provider order: Top 10 most commonly used providers first, then others alphabetically
  local providers=(
    # Top 10 commonly used providers (user-specified order)
    "Aliyun Dashscope (Qwen)|DASHSCOPE"
    "DeepSeek|DEEPSEEK"
    "Moonshot (Kimi)|MOONSHOT"
    "Zhipu AI|ZHIPUAI"
    "Minimax|MINIMAX|configureMinimaxProvider"
    "Azure OpenAI|AZURE|configureAzureProvider"
    "AWS Bedrock|BEDROCK|configureBedrockProvider"
    "Google Vertex AI|VERTEX|configureVertexProvider"
    "OpenAI|OPENAI"
    "OpenRouter|OPENROUTER"
    # Other providers (alphabetically ordered)
    "01.AI (Yi)|YI"
    "360 Zhinao|AI360"
    "Baichuan AI|BAICHUAN"
    "Baidu AI Cloud|BAIDU"
    "Claude|CLAUDE|configureClaudeProvider"
    "Cloudflare Workers AI|CLOUDFLARE|configureCloudflareProvider"
    "Cohere|COHERE"
    "DeepL|DEEPL|configureDeepLProvider"
    "Dify|DIFY|configureDifyProvider"
    "Doubao|DOUBAO"
    "Fireworks AI|FIREWORKS"
    "Github Models|GITHUB"
    "Google Gemini|GEMINI"
    "Grok|GROK"
    "Groq|GROQ"
    "Mistral AI|MISTRAL"
    "Ollama|OLLAMA|configureOllamaProvider"
    "iFlyTek Spark|SPARK|configureSparkProvider"
    "Stepfun|STEPFUN"
    "Tencent Hunyuan|HUNYUAN|configureHunyuanProvider"
    "Together AI|TOGETHERAI"
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
}

configureClaudeProvider() {
  read -r -u 3 -p "→ Enter API Key for Claude: " CLAUDE_API_KEY
  local DEFAULT_CLAUDE_VERSION="2023-06-01"
  readWithDefault "→ Enter API version for Claude (Default: $DEFAULT_CLAUDE_VERSION): " $DEFAULT_CLAUDE_VERSION
  CLAUDE_VERSION="$input"
  LLM_ENVS+=("CLAUDE_API_KEY" "CLAUDE_VERSION")
}

configureMinimaxProvider() {
  read -r -u 3 -p "→ Enter API Key for Minimax: " MINIMAX_API_KEY
  read -r -u 3 -p "→ Enter group ID for Minimax (only required when using ChatCompletion Pro): " MINIMAX_GROUP_ID
  LLM_ENVS+=("MINIMAX_API_KEY" "MINIMAX_GROUP_ID")
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
}

configureCloudflareProvider() {
  read -r -u 3 -p "→ Enter API Token for Cloudflare Workers AI: " CLOUDFLARE_API_KEY
  read -r -u 3 -p "→ Enter Cloudflare Account ID: " CLOUDFLARE_ACCOUNT_ID
  if [ -n "$CLOUDFLARE_API_KEY" ] && [ -n "$CLOUDFLARE_ACCOUNT_ID" ]; then
    CLOUDFLARE_CONFIGURED="placeholder"
  fi
  LLM_ENVS+=("CLOUDFLARE_API_KEY" "CLOUDFLARE_ACCOUNT_ID")
}

configureDeepLProvider() {
  read -r -u 3 -p "→ Enter API Key for DeepL: " DEEPL_API_KEY
  read -r -u 3 -p "→ Enter target language for DeepL (e.g., EN, ZH, JA): " DEEPL_TARGET_LANG
  if [ -n "$DEEPL_API_KEY" ] && [ -n "$DEEPL_TARGET_LANG" ]; then
    DEEPL_CONFIGURED="placeholder"
  fi
  LLM_ENVS+=("DEEPL_API_KEY" "DEEPL_TARGET_LANG")
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
}

configureHunyuanProvider() {
  read -r -u 3 -p "→ Enter Auth ID for Tencent Hunyuan: " HUNYUAN_AUTH_ID
  read -r -u 3 -p "→ Enter Auth Key for Tencent Hunyuan: " HUNYUAN_AUTH_KEY
  if [ -n "$HUNYUAN_AUTH_ID" ] && [ -n "$HUNYUAN_AUTH_KEY" ]; then
    HUNYUAN_CONFIGURED="placeholder"
  fi
  LLM_ENVS+=("HUNYUAN_AUTH_ID" "HUNYUAN_AUTH_KEY")
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

writeConfiguration() {
  local LLM_CONFIGS=""
  for env in "${LLM_ENVS[@]}"; do
    LLM_CONFIGS="$LLM_CONFIGS
${env}=${!env}"
  done
  cat <<EOF >$DATA_FOLDER/$CONFIG_FILENAME
MODE=full
O11Y=on
CONFIG_TEMPLATE=ai-gateway
GATEWAY_HTTP_PORT=${GATEWAY_HTTP_PORT}
GATEWAY_HTTPS_PORT=${GATEWAY_HTTPS_PORT}
CONSOLE_PORT=${CONSOLE_PORT}
${LLM_CONFIGS}
EOF
}

outputUsage() {
  echo -n "Usage: $(basename -- "$0") [OPTIONS...]"
  echo '
 -h, --help                 give this help list'
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

  outputWelcomeMessage
  exit 0
}

start() {
  echo "Starting Higress AI Gateway..."
  echo

  NORMALIZED_DATA_FOLDER_PATH="$(normalizePath "${DATA_FOLDER}")"
  NORMALIZED_CONFIG_FILE_PATH="$(normalizePath "${DATA_FOLDER}/${CONFIG_FILENAME}")"

  $DOCKER_COMMAND run --name "${CONTAINER_NAME}" -d \
    -p 127.0.0.1:$GATEWAY_HTTP_PORT:$GATEWAY_HTTP_PORT \
    -p 127.0.0.1:$GATEWAY_HTTPS_PORT:$GATEWAY_HTTPS_PORT \
    -p 127.0.0.1:$CONSOLE_PORT:$CONSOLE_PORT \
    --restart=always \
    --env-file "$NORMALIZED_CONFIG_FILE_PATH" \
    --mount "type=bind,source=$NORMALIZED_DATA_FOLDER_PATH,target=/data" "$IMAGE_REPO:$IMAGE_TAG" >/dev/null

  if [ $? -eq 0 ]; then
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
esac
