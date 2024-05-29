ARG HUB=higress-registry.cn-hangzhou.cr.aliyuncs.com/higress
ARG BASE_VERSION=2022-10-27T19-02-22
ARG CORE_VERSION=1.4.0
ARG CONSOLE_VERSION=1.4.0
ARG APISERVER_VERSION=0.0.14

FROM ${HUB}/api-server:${APISERVER_VERSION} as apiserver
FROM ${HUB}/higress:${CORE_VERSION} as controller
FROM ${HUB}/pilot:${CORE_VERSION} as pilot
FROM ${HUB}/gateway:${CORE_VERSION} as gateway
FROM ${HUB}/console:${CONSOLE_VERSION} as console
FROM eclipse-temurin:21-jre as jdk

FROM ${HUB}/base:${BASE_VERSION}

# Install API server
COPY --from=apiserver /apiserver /usr/local/bin/apiserver

# Install controller
COPY --from=controller /usr/local/bin/higress /usr/local/bin/higress

# Install pilot
COPY --from=pilot /usr/local/bin/pilot-discovery /usr/local/bin/pilot-discovery
COPY --from=pilot /var/lib/istio/envoy/*.json /var/lib/istio/envoy/
COPY --from=pilot /usr/local/bin/higress-pilot-start.sh /usr/local/bin/higress-pilot-start.sh

# Install gateway
COPY --from=gateway /usr/local/bin/pilot-agent /usr/local/bin/pilot-agent
COPY --from=gateway /usr/local/bin/envoy /usr/local/bin/envoy

# Install console
COPY --from=console /app /app

# Install JDK required by console
ENV JAVA_HOME=/opt/java/openjdk
COPY --from=jdk $JAVA_HOME $JAVA_HOME
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# Install supervisord and initialize related folders
RUN apt-get update && \
  apt-get install --no-install-recommends -y \
  supervisor \
  && apt-get clean \
  && rm -rf /var/log/*log /var/lib/apt/lists/* /var/log/apt/* /var/lib/dpkg/*-old /var/cache/debconf/*-old \
  && mkdir -p /var/log/higress \
  && chown 1337:1337 -R /var/log/higress \
  && mkdir /data \
  && chown 1337:1337 -R /data
COPY ./supervisord/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Initialize configurations
COPY ./meshConfig /etc/istio/config
COPY ./gateway/podinfo /etc/istio/pod
COPY ./scripts /usr/local/bin
COPY ./apiserver/config /app/kubeconfig
COPY ./config /opt/data/defaultConfig

EXPOSE 8080 8443 8001

ENTRYPOINT ["supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]