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

USE_EXTERNAL_NACOS="Y"
NACOS_CONTAINER_ARGS="-e NACOS_CORE_AUTH_ENABLED=true -e NACOS_CORE_AUTH_SERVER_IDENTITY_KEY=serverIdentity -e NACOS_CORE_AUTH_SERVER_IDENTITY_VALUE=security -e NACOS_CORE_AUTH_PLUGIN_NACOS_TOKEN_SECRET_KEY=SecretKey012345678901234567890123456789012345678901234567890123456789"

CONFIGURE_ARGS=""

CONFIGURE_INPUT="N
nacos://${LOCAL_IP}:8848
Y
nacos
nacos
higress-test
2b9841c866544379bb88ebee3021e341
admin
30001
30002
30003
30004
"

declare -A EXPECTED_ENVS=(
  ["COMPOSE_PROFILES"]=''
  ["NACOS_SERVER_URL"]="http://${LOCAL_IP}:8848/nacos"
  ["NACOS_NS"]='higress-test'
  ["NACOS_USERNAME"]='nacos'
  ["NACOS_PASSWORD"]='nacos'
  ["HIGRESS_CONSOLE_PASSWORD"]='admin'
  ["NACOS_DATA_ENC_KEY"]='2b9841c866544379bb88ebee3021e341'
  ["NACOS_HTTP_PORT"]='8848'
  ["NACOS_GRPC_PORT"]='9848'
  ["GATEWAY_HTTP_PORT"]='30001'
  ["GATEWAY_HTTPS_PORT"]='30002'
  ["GATEWAY_METRICS_PORT"]='30003'
  ["CONSOLE_PORT"]='30004'
)