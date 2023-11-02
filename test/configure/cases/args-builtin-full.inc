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

CONFIGURE_ARGS="--use-builtin-nacos --data-enc-key=2b9841c866544379bb88ebee3021e341 --nacos-ns=higress-test --nacos-port=30001 --gateway-http-port=30002 --gateway-https-port=30003 --gateway-metrics-port=30004 --console-port=30005"

CONFIGURE_INPUT=""

declare -A EXPECTED_ENVS=(
  ["COMPOSE_PROFILES"]='nacos'
  ["CONFIG_STORAGE"]='nacos'
  ["FILE_ROOT_DIR"]=''
  ["NACOS_SERVER_URL"]='http://nacos:8848/nacos'
  ["NACOS_NS"]='higress-test'
  ["NACOS_USERNAME"]=''
  ["NACOS_PASSWORD"]=''
  ["NACOS_DATA_ENC_KEY"]='2b9841c866544379bb88ebee3021e341'
  ["NACOS_HTTP_PORT"]='30001'
  ["NACOS_GRPC_PORT"]='31001'
  ["GATEWAY_HTTP_PORT"]='30002'
  ["GATEWAY_HTTPS_PORT"]='30003'
  ["GATEWAY_METRICS_PORT"]='30004'
  ["CONSOLE_PORT"]='30005'
)