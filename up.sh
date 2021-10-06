#!/usr/bin/bash

# variables
KIND_CLUSTER_NAME="web-app"
DOCKER_HUB_USER="jomadu"
IMAGE_BASE_NAME="web-app"
FRONTEND_IMAGE_NAME="frontend"
BACKEND_IMAGE_NAME="backend"
TAG="latest"
FRONTEND_FULL_IMAGE_NAME="${DOCKER_HUB_USER}/${IMAGE_BASE_NAME}_${FRONTEND_IMAGE_NAME}:${TAG}"
BACKEND_FULL_IMAGE_NAME="${DOCKER_HUB_USER}/${IMAGE_BASE_NAME}_${BACKEND_IMAGE_NAME}:${TAG}"

wait_for_result() {
  local cmd=$1
  local cmd_result=""
  local desired_result=$2
  local tries=10
  local delay=5
  local try=0
  local do=true
  while $do || [[ $try -lt $tries && "$cmd_result" != "$desired_result" ]]; do
    if [[ "$do" == "false" ]]; then
      sleep $delay
    fi
    try=$((try+1))
    do=false
    cmd_result=$(eval $cmd)
    echo "try: $try, cmd: '$cmd', cmd_result: '$cmd_result', desired_result: '$desired_result'"
  done

  if [[ "$cmd_result" == "$desired_result" ]]; then
    echo "desired result met"
    return 0
  else
    echo "exceeded number of tries before meeting desired result"
    return 1
  fi
}

delete_existing_cluster() {
  if [[ $(kind get clusters -q | grep ${KIND_CLUSTER_NAME}) ]]; then
    kind delete cluster --name "${KIND_CLUSTER_NAME}"
  else
    echo "kind cluster '$KIND_CLUSTER_NAME' doesn't exist."
  fi
}


# build docker files
docker build -t ${FRONTEND_FULL_IMAGE_NAME} ./frontend
docker build -t ${BACKEND_FULL_IMAGE_NAME} ./backend

# delete any existing cluster
delete_existing_cluster

# create cluster
kind create cluster --name "${KIND_CLUSTER_NAME}" --config=./cluster-config.yaml

# # set kubectl context
kubectl config use-context kind-${KIND_CLUSTER_NAME}

# apply ingress controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

wait_for_result "kubectl get pod --namespace ingress-nginx --selector=app.kubernetes.io/component=controller -o json | jq '.items | length'" "1"

if [[ $? -ne 0 ]]; then
  echo "failed to create ingress controller. exiting ..."
  delete_existing_cluster
  exit 1
fi

echo "waiting for ingress controller to be ready..."
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s

if [[ $? -ne 0 ]]; then
  echo "timed out waiting for ingress controller to be ready. exiting ..."
  delete_existing_cluster
  exit 1
fi

# load images into cluster
kind load docker-image ${FRONTEND_FULL_IMAGE_NAME} --name ${KIND_CLUSTER_NAME}
kind load docker-image ${BACKEND_FULL_IMAGE_NAME} --name ${KIND_CLUSTER_NAME}

# # apply backend-manifest
kubectl apply -f ./backend/backend-manifest.yaml -f ./frontend/frontend-manifest.yaml -f ./ingress-deployment.yaml