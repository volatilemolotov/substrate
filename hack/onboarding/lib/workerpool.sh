#!/usr/bin/env bash

# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# workerpool.sh - make sure a node pool capable of running the Substrate
# WorkerPool (microVMs need nested/hardware virtualization) exists, and
# optionally deploy the default WorkerPool onto it.
#
# Two public entry points, called separately by onboard.sh so that
# autoscaling.sh's HPA/capacity-buffer step can run between them:
#   ensure_virt_nodepool     - node pool ready; sets WORKERPOOL_NODEPOOL_NAME
#   deploy_default_workerpool - ask yes/no, deploy the WorkerPool if so

# find_virt_nodepool
# TODO(gcloud): list node pools for CLUSTER_NAME and find one with
# nested virtualization enabled, e.g.:
#   gcloud container node-pools list --cluster="${CLUSTER_NAME}" \
#     --project="${CLUSTER_PROJECT}" --location="${CLUSTER_LOCATION}" \
#     --format=json
# then check each pool's `config.advancedMachineFeatures.enableNestedVirtualization`
# (and/or a suitable machine family) for a match.
#
# Prints the matching node pool name to stdout if found, prints nothing
# and returns 1 if not found.
find_virt_nodepool() {
  log_stub "looking for a node pool with hardware virtualization enabled (gcloud container node-pools list)"
  if [[ "${ONBOARD_STUB_VIRT_NODEPOOL_FOUND}" == "true" ]]; then
    echo "existing-virt-pool"
    return 0
  fi
  return 1
}

# create_workerpool_nodepool_defaults
# TODO(gcloud): create a node pool using the DEFAULT_WORKERPOOL_* values
# from config.sh, with nested virtualization enabled, e.g. roughly:
#   gcloud container node-pools create "${DEFAULT_WORKERPOOL_NODEPOOL_NAME}" \
#     --cluster="${CLUSTER_NAME}" --project="${CLUSTER_PROJECT}" \
#     --location="${CLUSTER_LOCATION}" \
#     --machine-type="${DEFAULT_WORKERPOOL_MACHINE_TYPE}" \
#     --num-nodes="${DEFAULT_WORKERPOOL_NODE_COUNT}" \
#     --disk-size="${DEFAULT_WORKERPOOL_DISK_SIZE_GB}" \
#     --enable-nested-virtualization   # (flag name TBD)
#
# Prints the created node pool name to stdout.
create_workerpool_nodepool_defaults() {
  log_stub "creating node pool '${DEFAULT_WORKERPOOL_NODEPOOL_NAME}' with defaults (gcloud container node-pools create)"
  log_info "machine-type=${DEFAULT_WORKERPOOL_MACHINE_TYPE} nodes=${DEFAULT_WORKERPOOL_NODE_COUNT} disk=${DEFAULT_WORKERPOOL_DISK_SIZE_GB}GB"
  spinner_wait "Creating node pool..." 1
  echo "${DEFAULT_WORKERPOOL_NODEPOOL_NAME}"
}

# print_manual_nodepool_commands
# TODO: print the real gcloud command(s) a user would run by hand,
# pre-filled with CLUSTER_NAME/CLUSTER_PROJECT/CLUSTER_LOCATION.
print_manual_nodepool_commands() {
  cat <<EOF

  # TODO(gcloud): replace with the real command(s).
  gcloud container node-pools create NODE_POOL_NAME \\
    --cluster="${CLUSTER_NAME}" \\
    --project="${CLUSTER_PROJECT}" \\
    --location="${CLUSTER_LOCATION}" \\
    --machine-type=MACHINE_TYPE \\
    --num-nodes=NODE_COUNT \\
    --enable-nested-virtualization   # flag name TBD

EOF
}

# ensure_virt_nodepool
# Sets WORKERPOOL_NODEPOOL_NAME on success. Exits the calling script if
# the user cancels.
ensure_virt_nodepool() {
  log_step "Checking for a node pool with hardware virtualization enabled"

  local found
  if found="$(find_virt_nodepool)"; then
    WORKERPOOL_NODEPOOL_NAME="${found}"
    log_success "Found node pool: ${WORKERPOOL_NODEPOOL_NAME}"
    return 0
  fi

  log_warn "No node pool with hardware virtualization enabled was found on ${CLUSTER_NAME}"

  local choice
  choice="$(select_from_list "How do you want to create it?" \
    "Create it now using recommended defaults" \
    "I'll run the gcloud commands myself" \
    "Cancel")" || exit 1

  case "${choice}" in
    "Create it now using recommended defaults")
      log_step "Creating worker node pool with defaults"
      WORKERPOOL_NODEPOOL_NAME="$(create_workerpool_nodepool_defaults)"
      log_success "Created node pool: ${WORKERPOOL_NODEPOOL_NAME}"
      ;;
    "I'll run the gcloud commands myself")
      log_info "Run the following, then come back to this terminal:"
      print_manual_nodepool_commands
      if ! confirm "Have you created the node pool?" "y"; then
        log_info "Cancelled. Nothing was changed."
        exit 0
      fi
      # TODO(gcloud): re-run find_virt_nodepool to confirm + capture the
      # real name instead of trusting the user's input blindly.
      read -r -p "Node pool name: " WORKERPOOL_NODEPOOL_NAME
      ;;
    "Cancel")
      log_info "Cancelled. Nothing was changed."
      exit 0
      ;;
  esac
}

# install_workerpool
# TODO: presumably `hack/install-demo-autoscaled-workerpool.sh` or similar,
# pointed at WORKERPOOL_NODEPOOL_NAME.
install_workerpool() {
  log_stub "installing the Substrate WorkerPool onto '${WORKERPOOL_NODEPOOL_NAME}'"
  spinner_wait "Deploying WorkerPool resources..." 1
}

# deploy_default_workerpool
# Public entry point for the "deploy the default WorkerPool?" step. Runs
# after ensure_virt_nodepool (node pool ready) and
# configure_workerpool_autoscaling (autoscaling.sh, decided how HPA +
# capacity buffer will be set up). Declining is a normal outcome, not a
# cancellation -- the rest of onboarding is already done at this point.
deploy_default_workerpool() {
  log_step "Deploy default Substrate WorkerPool"

  if ! confirm "Deploy the default Substrate WorkerPool now?" "y"; then
    log_info "Skipped deploying the default WorkerPool. You can deploy it later."
    return 0
  fi

  install_workerpool
  log_success "Substrate WorkerPool installed on node pool '${WORKERPOOL_NODEPOOL_NAME}'"
}
