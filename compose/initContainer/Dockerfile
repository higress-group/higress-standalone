FROM docker.io/ubuntu

WORKDIR /workspace

COPY ./src/ ./

RUN apt-get update \
  && apt-get install -y curl openssl xxd \
  && rm -rf /var/lib/apt/lists/*

ENTRYPOINT [ "/bin/bash", "./run.sh" ]