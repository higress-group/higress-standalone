#! /bin/bash

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

VOLUMES_ROOT="/mnt/volumes"

checkApiServer() {
  echo "Checking API server configurations..."

  if [ ! -d "$VOLUMES_ROOT/api/" ]; then
    echo "  The volume of api is missing."
    exit -1 
  fi
  cd "$VOLUMES_ROOT/api"

  if [ ! -f ca.key ] || [ ! -f ca.crt ]; then
    echo "  CA certificate files of API server are missing."
    exit -1 
  fi
  if [ ! -f server.key ] || [ ! -f server.crt ]; then
    echo "  Server certificate files of API server are missing."
    exit -1 
  fi
  if [ ! -f client.key ] || [ ! -f client.crt ]; then
    echo "  Client certificate files of API server are missing."
    exit -1 
  fi
  if [ ! -f $VOLUMES_ROOT/kube/config ]; then
    echo "  The kubeconfig file to access API server is missing."
    exit -1 
  fi
}

checkApiServer
