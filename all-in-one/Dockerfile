ARG HUB=higress-registry.cn-hangzhou.cr.aliyuncs.com/higress
ARG BASE_VERSION=2022-10-27T19-02-22
ARG CORE_VERSION=2.0.7
ARG CONSOLE_VERSION=2.0.4
ARG APISERVER_VERSION=0.0.19
ARG PROMETHEUS_VERSION=v2.40.7
ARG PROMTAIL_VERSION=2.9.4
ARG LOKI_VERSION=2.9.4
ARG GRAFANA_VERSION=9.3.6

FROM ${HUB}/api-server:${APISERVER_VERSION} AS apiserver
FROM ${HUB}/higress:${CORE_VERSION} AS controller
FROM ${HUB}/pilot:${CORE_VERSION} AS pilot
FROM ${HUB}/gateway:${CORE_VERSION} AS gateway
FROM ${HUB}/console:${CONSOLE_VERSION} AS console
FROM ${HUB}/prometheus:${PROMETHEUS_VERSION} AS prometheus
FROM ${HUB}/promtail:${PROMTAIL_VERSION} AS promtail
FROM ${HUB}/loki:${LOKI_VERSION} AS loki
FROM ${HUB}/grafana:${GRAFANA_VERSION} AS grafana
FROM ${HUB}/eclipse-temurin:21-jre AS jdk

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
COPY --from=gateway /usr/local/bin/pilot-agent /usr/local/bin/pilot-agent
COPY --from=gateway /usr/local/bin/envoy /usr/local/bin/envoy
COPY --from=gateway /usr/local/bin/higress-proxy-*.sh /usr/local/bin/
RUN chmod a+x /usr/local/bin/higress-proxy-container-init.sh; \
  sed -i 's/1337/0/g' /usr/local/bin/higress-proxy-container-init.sh; \
  /usr/local/bin/higress-proxy-container-init.sh
COPY --from=gateway /usr/local/bin/supercronic* /usr/local/bin/

# Install console
COPY --from=console /app /app

# Install JDK required by console
ENV JAVA_HOME=/opt/java/openjdk
COPY --from=jdk $JAVA_HOME $JAVA_HOME
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# Install Prometheus
COPY --from=prometheus /bin/prometheus /usr/local/bin/prometheus

# Install Promtail
COPY --from=promtail /usr/bin/promtail /usr/local/bin/promtail

# Install Loki
COPY --from=loki /usr/bin/loki /usr/local/bin/loki

# Install Grafana
COPY --from=grafana /usr/share/grafana /usr/share/grafana
COPY --from=grafana /run.sh /usr/local/bin/grafana.sh

# Install supervisord, logrotate, cron and initialize related folders
RUN apt-get update --allow-unauthenticated && \
  apt-get install --no-install-recommends -y --allow-unauthenticated \
  supervisor logrotate cron \
  && apt-get upgrade -y --allow-unauthenticated \
  && apt-get clean \
  && rm -rf /var/log/*log /var/lib/apt/lists/* /var/log/apt/* /var/lib/dpkg/*-old /var/cache/debconf/*-old \
  && mkdir -p /var/log/higress \
  && mkdir /data
COPY ./supervisord/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Initialize configurations
COPY ./meshConfig /etc/istio/config
COPY ./gateway/podinfo /etc/istio/pod
COPY ./scripts /usr/local/bin
COPY ./apiserver/config /app/kubeconfig
COPY ./config /opt/data/defaultConfig
COPY ./prometheus /etc/prometheus
COPY ./promtail /etc/promtail
COPY ./loki /etc/loki
COPY ./grafana /etc/grafana

EXPOSE 8080 8443 8001

ENTRYPOINT ["supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
