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

CONFIGURE_ARGS=""

CONFIGURE_INPUT="nacos
Y
admin




30000
"

declare -A EXPECTED_ENVS=(
  ["COMPOSE_PROFILES"]='nacos'
  ["CONFIG_STORAGE"]='nacos'
  ["FILE_ROOT_DIR"]=''
  ["NACOS_SERVER_URL"]='http://nacos:8848/nacos'
  ["NACOS_NS"]='higress-system'
  ["NACOS_USERNAME"]=''
  ["NACOS_PASSWORD"]=''
  ["HIGRESS_CONSOLE_PASSWORD"]='admin'
  ["NACOS_HTTP_PORT"]='8848'
  ["NACOS_GRPC_PORT"]='9848'
  ["GATEWAY_HTTP_PORT"]='80'
  ["GATEWAY_HTTPS_PORT"]='443'
  ["GATEWAY_METRICS_PORT"]='15020'
  ["CONSOLE_PORT"]='30000'
)