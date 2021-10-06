#!/usr/bin/bash

# variables
KIND_CLUSTER_NAME="web-app"

# delete any existing cluster
if [[ $(kind get clusters -q | grep ${KIND_CLUSTER_NAME}) ]]; then
  kind delete cluster --name "${KIND_CLUSTER_NAME}"
fi