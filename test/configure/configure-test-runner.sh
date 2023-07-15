#!/usr/bin/env bash

#  Copyright (c) 2023 Alibaba Group Holding Ltd.

#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at

#       http:www.apache.org/licenses/LICENSE-2.0

#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

# $1 case script file

NACOS_CONTAINER_NAME="higress-standalone-test-nacos"
NACOS_IMAGE_TAG="v2.2.3"

cd "$(dirname -- "$0")"
SCRIPT_DIR=$(pwd -P)
cd ..
ROOT=$(dirname -- "$(pwd -P)")
cd - > /dev/null

source "$SCRIPT_DIR/../utils.inc"

fail_trap() {
  result=$?
  echo ""
  echo "Cleaning up..."
  if [ "$USE_EXTERNAL_NACOS" == "Y" ]; then
    docker container stop "$NACOS_CONTAINER_NAME" > /dev/null
  fi
  bash "$ROOT/bin/reset.sh"
  [ $result -ne 0 ] && echo "Test case failed with $result."
  exit $result
}

trap "fail_trap" EXIT

# Configure the Higress instance
configure() {
  echo ""
  echo "Configuring Higress instance..."
  echo -e "$CONFIGURE_INPUT" | bash "$ROOT/bin/configure.sh" $CONFIGURE_ARGS
  if [ $? -ne 0 ]; then
    echo "Failed to configure the test Higress instance."
    exit 1
  fi
  echo "Done"
}

validateEnvFile() {
  # Validate the generated .env file
  echo ""
  echo "Validating generated .env file..."
  envFileContent=$(cat "$ROOT/compose/.env")
  for key in ${!EXPECTED_ENVS[*]}
  do
    line="${key}='${EXPECTED_ENVS[$key]}'"
    if [[ $envFileContent != *"${line}"* ]]; then
      echo "Configuration item \"$line\" isn't found in the .env file."
      exit 1
    fi
  done
  echo "Done"
}

###############################################################################

if [ -z "$1" ]; then
  echo "Please specify the test case to run."
  exit 1
fi
if [ ! -f "$1" ]; then
  echo "Please specify a valid test case file to run."
  exit 1
fi

# Load test case definition.
source "$1"

if [ "$USE_EXTERNAL_NACOS" == "Y" ]; then
  docker run --name "$NACOS_CONTAINER_NAME" -e MODE=standalone ${NACOS_CONTAINER_ARGS} \
    -p 8848:8848 --rm -d nacos/nacos-server:$NACOS_IMAGE_TAG > /dev/null
fi

configure
validateEnvFile
