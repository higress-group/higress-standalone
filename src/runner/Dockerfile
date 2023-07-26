FROM docker.io/ubuntu

WORKDIR /workspace

RUN apt-get update \
  && apt-get install -y curl openssl xxd jq \
  && rm -rf /var/lib/apt/lists/*; \
  curl -sSL -o /usr/bin/yq https://github.com/mikefarah/yq/releases/download/v4.34.2/yq_linux_amd64 && chmod +x /usr/bin/yq;

ENTRYPOINT [ "/bin/bash" ]