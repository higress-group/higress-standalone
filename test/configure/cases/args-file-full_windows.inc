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

CONFIGURE_ARGS="-c file:///c/temp/higress/data --console-password=helloworld --gateway-http-port=30002 --gateway-https-port=30003 --gateway-metrics-port=30004 --console-port=30005"

CONFIGURE_INPUT=""

declare -A EXPECTED_ENVS=(
  ["COMPOSE_PROFILES"]=''
  ["CONFIG_STORAGE"]='file'
  ["FILE_ROOT_DIR"]='C:\temp\higress\data'
  ["GATEWAY_HTTP_PORT"]='30002'
  ["GATEWAY_HTTPS_PORT"]='30003'
  ["GATEWAY_METRICS_PORT"]='30004'
  ["CONSOLE_PORT"]='30005'
)