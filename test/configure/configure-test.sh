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

cd "$(dirname -- "$0")"
SCRIPT_DIR=$(pwd -P)
cd ..
ROOT=$(dirname -- "$(pwd -P)")
cd - >/dev/null

source "$SCRIPT_DIR/../utils.inc"

# Clean up before starting the test.
echo "Resetting existed configurations before testing..."
bash "$ROOT/bin/reset.sh"
check_exit_code "Failed to reset configurations before testing with $?."
echo ""

declare -A testResults

if [ -z "$1" ]; then
  for fullname in $SCRIPT_DIR/cases/*.inc; do
    [ -e "$fullname" ] || continue
    filename=$(basename -- "$fullname")
    filename=${filename%.*}
    echo "=========================================================="
    echo "--> Executing test case [$filename] <--"
    bash $SCRIPT_DIR/configure-test-runner.sh "$fullname"
    testResults["$filename"]=$?
    echo "=========================================================="
    echo ""
  done
else
  filename="$1.inc"
  fullname="$SCRIPT_DIR/cases/$filename"
  echo "=========================================================="
  echo "--> Executing test case [$filename] <--"
  bash $SCRIPT_DIR/configure-test-runner.sh "$fullname"
  testResults["$filename"]=$?
  echo "=========================================================="
  echo ""
fi

echo "Results:"
for test in "${!testResults[@]}" ; do
  [ ${testResults[$test]} -eq 0 ] && echo -e "  ${test}:\t\033[0;32mPassed\033[0m" || echo -e "  ${test}:\t\033[0;31mFailed\033[0m"
done
