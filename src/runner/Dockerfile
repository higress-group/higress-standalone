FROM docker.io/ubuntu

ARG YQ_VERSION

WORKDIR /workspace

RUN apt-get update \
  && apt-get install -y curl wget openssl xxd jq \
  && rm -rf /var/lib/apt/lists/*; \
  arch="$(dpkg --print-architecture)"; arch="${arch##*-}"; \
  yq_version=${YQ_VERSION:-4.34.2}; \
  echo "arch:       '$arch'"; \
  echo "yq_version: '$yq_version'"; \ 
  case "$arch" in \
    'amd64') \
      yq_url="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64"; \
      ;; \
    'arm64') \
      yq_url="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_arm64"; \
      ;; \
  esac; \
  echo "yq_url: '$yq_url'"; \
  wget -O /usr/bin/yq "$yq_url" --progress=dot:giga; \
  chmod +x /usr/bin/yq; \
  echo "done";

ENTRYPOINT [ "/bin/bash" ]