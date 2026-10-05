ARG HUB=higress-registry.cn-hangzhou.cr.aliyuncs.com/higress
ARG BASE_VERSION=2022-10-27T19-02-22
ARG CORE_VERSION=2.2.5
ARG CONSOLE_VERSION=2.2.5
ARG APISERVER_VERSION=0.1.0
ARG ENVOY_VERSION=2.2.5
ARG PLUGIN_SERVER_VERSION=2.2.5
ARG CONTROLLER_IMAGE=higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/higress:2.2.5@sha256:38663f158d1e9aa8233f268cc3bc4776aaaa5d5e1e15fdde88db0c7a626ef0f4
ARG PILOT_IMAGE=higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/pilot:2.2.5@sha256:10334ca1baf0d8e1f8a97bb47845d6c12d118eda3d330c86a7707aa9f0628aa9
ARG GATEWAY_IMAGE=higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/gateway:2.2.5@sha256:a82de493902012ce6b555ecb2244156f3c73824474d67549144a7efa334d0299
ARG PLUGIN_SERVER_IMAGE=higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/plugin-server:2.2.5@sha256:ec63c6dfd18e77917faaecfd5fcdebde7e0bc40d42effa3b6d6f77d4f5c2fd40

FROM ${HUB}/api-server:${APISERVER_VERSION} AS apiserver
FROM ${CONTROLLER_IMAGE} AS controller
FROM ${PILOT_IMAGE} AS pilot
FROM ${GATEWAY_IMAGE} AS gateway
FROM ${HUB}/console:${CONSOLE_VERSION} AS console
FROM ${HUB}/eclipse-temurin:21-jre AS jdk
FROM ${PLUGIN_SERVER_IMAGE} AS plugin-server

FROM ${HUB}/base:${BASE_VERSION}

# Install API server
COPY --from=apiserver /apiserver /usr/local/bin/apiserver

# Install controller
COPY --from=controller /usr/local/bin/higress /usr/local/bin/higress

# Install pilot
COPY --from=pilot /usr/local/bin/pilot-discovery /usr/local/bin/pilot-discovery
COPY --from=pilot /usr/local/bin/higress-pilot-start.sh /usr/local/bin/higress-pilot-start.sh

# Install gateway
COPY --from=gateway /var/lib/istio/envoy/*.json /var/lib/istio/envoy/
COPY --from=gateway /var/lib/istio/envoy/*.so /var/lib/istio/envoy/
COPY --from=gateway /usr/local/bin/pilot-agent /usr/local/bin/pilot-agent
COPY --from=gateway /usr/local/bin/higress-proxy-*.sh /usr/local/bin/
RUN chmod a+x /usr/local/bin/higress-proxy-container-init.sh; \
  sed -i 's/1337/0/g' /usr/local/bin/higress-proxy-container-init.sh; \
  /usr/local/bin/higress-proxy-container-init.sh
COPY --from=gateway /usr/local/bin/supercronic* /usr/local/bin/

# Install console
COPY --from=console /app /app

# Install plugin-server (nginx with wasm plugins)
COPY --from=plugin-server /usr/share/nginx/html/plugins /usr/share/nginx/html/plugins

# Install JDK required by console
ENV JAVA_HOME=/opt/java/openjdk
COPY --from=jdk $JAVA_HOME $JAVA_HOME
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# Install supervisord, logrotate, cron and initialize related folders
# Also download optimized envoy binary
ARG ENVOY_VERSION
RUN arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) envoy_arch="amd64" ;; \
    arm64) envoy_arch="arm64" ;; \
    *) echo "Unsupported architecture: $arch" && exit 1 ;; \
  esac; \
  apt-get update --allow-unauthenticated; \
  apt-get install --no-install-recommends -y --allow-unauthenticated \
    wget supervisor logrotate cron nginx; \
  apt-get upgrade -y --allow-unauthenticated; \
  apt-get clean; \
  rm -rf /var/log/*log /var/lib/apt/lists/* /var/log/apt/* /var/lib/dpkg/*-old /var/cache/debconf/*-old; \
  wget -q "https://github.com/higress-group/proxy/releases/download/v${ENVOY_VERSION}/envoy-${envoy_arch}.tar.gz" -O /tmp/envoy.tar.gz && \
  tar -xzf /tmp/envoy.tar.gz -C / && \
  rm /tmp/envoy.tar.gz && \
  chmod +x /usr/local/bin/envoy && \
  test -x /usr/local/bin/envoy && \
  arch="${arch##*-}" && \
  wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$arch -O /usr/local/bin/yq && \
  chmod +x /usr/local/bin/yq && \
  test -x /usr/local/bin/yq && \
  mkdir -p /var/log/higress && \
  mkdir /data;

COPY ./supervisord/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Initialize configurations
COPY ./meshConfig /etc/istio/config
COPY ./gateway/podinfo /etc/istio/pod
COPY ./scripts /usr/local/bin
COPY ./apiserver/config /app/kubeconfig
COPY ./config /opt/data/defaultConfig
COPY ./plugin-server/nginx.conf /etc/nginx/plugin-server/nginx.conf

EXPOSE 8080 8443 8001

ENTRYPOINT ["supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
