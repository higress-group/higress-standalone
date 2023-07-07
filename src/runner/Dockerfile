FROM docker.io/ubuntu

WORKDIR /workspace

RUN apt-get update \
  && apt-get install -y curl openssl xxd jq \
  && rm -rf /var/lib/apt/lists/*

ENTRYPOINT [ "/bin/bash" ]