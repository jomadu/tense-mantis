#!/usr/bin/env bash

#-------------------------------------------------------------
# Script Boilerplate
#-------------------------------------------------------------
# Reference:
# betterdev.blog/minimal-safe-bash-script-template/
#-------------------------------------------------------------

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v]

Bring up, clean, or bring down local cluster

Available options:

-h, --help         Print this help and exit
-v, --verbose      Print script debug info
-u, --up           Bring up local cluster
-d, --down         Bring down local cluster
-c, --clean        Clean up local cluster

Requirements:

* kind - https://kind.sigs.k8s.io/
* kubectl - https://kubernetes.io/docs/tasks/tools/
* docker - https://docs.docker.com/get-docker/
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

parse_params() {
  # default values of variables set from params
  up=0
  down=0
  clean=0

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -u | --up) up=1 ;;
    -d | --down) down=1 ;;
    -c | --clean) clean=1 ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  [[ "$up" -eq "0" ]] && ! [[ "$down" -eq "0" || "$clean" -eq "0" ]] && die "must specify either -u | --up or ( -d | --down or -c | --clean ). 'run.sh --help' for usage."

  return 0
}

parse_params "$@"
setup_colors

#-----------------
# Script Functions
#-----------------

# Variable
CONFIG_FILE="run.config"
COMPONENTS=$(cat $CONFIG_FILE | jq -r '.components')
COMPONENT_KEYS=( $(echo $COMPONENTS | jq -r 'keys | .[]') )
KIND_CLUSTER_NAME=$(cat $CONFIG_FILE | jq -r '.variables.kindClusterName')
DOCKER_HUB_USER=$(cat $CONFIG_FILE | jq -r '.variables.dockerHubUser')
IMAGE_BASE_NAME=$(cat $CONFIG_FILE | jq -r '.variables.imageBaseName')
TAG="latest"

[[ "$KIND_CLUSTER_NAME" == "null" || "$DOCKER_HUB_USER" == "null" || "$IMAGE_BASE_NAME"  == "null" || "$COMPONENTS" == "null" ]] && die "run.config must specify dictionary .components, and values for .variables.kindClusterName, .variables.dockerHubUser, .variables.imageBaseName "

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
    msg "try: $try, cmd: '$cmd', cmd_result: '$cmd_result', desired_result: '$desired_result'"
  done

  if [[ "$cmd_result" == "$desired_result" ]]; then
    msg "desired result met"
    return 0
  else
    msg "exceeded number of tries before meeting desired result"
    return 1
  fi
}

create_full_image_name_ret=
create_full_image_name () {
  local component=$1
  create_full_image_name_ret="${DOCKER_HUB_USER}/${IMAGE_BASE_NAME}_${component}:${TAG}"
}

cluster_exists() {
  if [[ $(kind get clusters -q | grep ${KIND_CLUSTER_NAME}) ]]; then
    return 0
  else
    return 1
  fi
}

use_cluster_context() {
  kubectl config use-context kind-${KIND_CLUSTER_NAME}
}

clean_up_cluster() {
  if cluster_exists; then
    msg "cleaning up cluster"
    use_cluster_context
    kubectl delete deployment,pod,service,ingress --all
    msg "cleaned up cluster"
  else
    msg "kind cluster '$KIND_CLUSTER_NAME' doesn't exist."
  fi
}

create_cluster() {
  kind create cluster --name "${KIND_CLUSTER_NAME}" --config=./cluster-config.yaml
  use_cluster_context
  
  # apply ingress controller
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

  wait_for_result "kubectl get pod --namespace ingress-nginx --selector=app.kubernetes.io/component=controller -o json | jq '.items | length'" "1"

  if [[ "$?" -ne "0" ]]; then
    delete_cluster
    die "failed to create ingress controller"
  fi

  msg "waiting for ingress controller to be ready..."
  kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=120s

  if [[ "$?" -ne "0" ]]; then
    delete_cluster
    die "timed out waiting for ingress controller to be ready"
  fi
}

delete_cluster() {
  if cluster_exists; then
    kind delete cluster --name "${KIND_CLUSTER_NAME}"
  else
    msg "kind cluster '$KIND_CLUSTER_NAME' doesn't exist."
  fi
}

build_dockerfiles() {
  for component_key in "${COMPONENT_KEYS[@]}"; do
    local dockerfiles=( $(echo $COMPONENTS | jq -r --arg component_key "$component_key" '.[$component_key].dockerfile') )
    for dockerfile in "${dockerfiles[@]}"; do
      if [[ "$dockerfile" != "null" ]]; then
        create_full_image_name $component_key
        docker build -t $create_full_image_name_ret $dockerfile
      fi
    done
  done
}

load_docker_images_onto_cluster() {
  for component_key in "${COMPONENT_KEYS[@]}"; do
    local dockerfiles=( $(echo $COMPONENTS | jq -r --arg component_key "$component_key" '.[$component_key].dockerfile') )
    for dockerfile in "${dockerfiles[@]}"; do
      if [[ "$dockerfile" != "null" ]]; then
        create_full_image_name $component_key
        kind load docker-image $create_full_image_name_ret --name $KIND_CLUSTER_NAME
      fi
    done
  done
}

apply_manifests() {
  local apply_args=""
  for component_key in "${COMPONENT_KEYS[@]}"; do
    local manifests=( $(echo $COMPONENTS | jq -r --arg component_key "$component_key" '.[$component_key].manifest') )
    for manifest in "${manifests[@]}"; do
      if [[ "$manifest" != "null" ]]; then
        apply_args="${apply_args} -f $manifest"
      fi
    done
  done

  if [[ ! -z "$apply_args" ]]; then
    kubectl apply $apply_args
  fi
}

# ------------
# Script Logic
# ------------

if [[ "$up" -eq "1" ]]; then
  if cluster_exists ; then
    clean_up_cluster
  else
    create_cluster
  fi
  build_dockerfiles
  use_cluster_context
  load_docker_images_onto_cluster
  apply_manifests
fi

if [[ "$down" -eq "1" ]]; then
  delete_cluster
elif [[ "$clean" -eq "1" ]]; then
  clean_up_cluster
fi

