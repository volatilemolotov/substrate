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
# Lists node pools on the selected cluster and looks for one with nested
# virtualization enabled (config.advancedMachineFeatures.enableNestedVirtualization
# in the raw API resource -- confirmed via a live `--format=json` call;
# note this is NOT reachable through `--format=value(...)`, per the same
# gcloud display-transform behavior documented in registry.sh for
# Artifact Registry repos, so this uses json+jq too rather than value()).
#
# Prints the first match's name to stdout. Returns 1 either because the
# gcloud call itself failed (logged before returning) or because no pool
# matched (silent -- ensure_virt_nodepool has its own message for that).
find_virt_nodepool() {
  require_cmd gcloud
  require_cmd jq

  local json
  if ! json="$(gcloud container node-pools list \
    --cluster="${CLUSTER_NAME}" --project="${CLUSTER_PROJECT}" --location="${CLUSTER_LOCATION}" \
    --format=json)"; then
    log_error "gcloud failed to list node pools for cluster '${CLUSTER_NAME}'. See the error above and check your gcloud setup."
    return 1
  fi

  local pool_name
  pool_name="$(echo "${json}" | jq -r '
    [.[] | select(.config.advancedMachineFeatures.enableNestedVirtualization == true)][0].name // empty
  ')"

  [[ -n "${pool_name}" ]] || return 1
  echo "${pool_name}"
}

# create_workerpool_nodepool_defaults
# Creates a node pool using the DEFAULT_WORKERPOOL_* values from
# config.sh, with nested virtualization enabled.
#
# --enable-nested-virtualization (confirmed via `gcloud container
# node-pools create --help`) requires UBUNTU_CONTAINERD, or
# COS_CONTAINERD at version 1.28.4-gke.1083000+ -- not forcing
# --image-type here since the default is COS_CONTAINERD and
# MIN_GKE_VERSION (config.sh) is already well above that floor, so the
# node pool's image should qualify without an explicit override.
#
# Prints the created node pool name to stdout. Unlike this file's other
# gcloud calls (list/describe with an explicit --format), `create`
# prints a human-readable result table to stdout by default -- stdout is
# redirected to /dev/null here (stderr stays visible for real errors) so
# that table can't get captured into WORKERPOOL_NODEPOOL_NAME alongside
# the real name via the caller's `$(...)`. Found the hard way: it did,
# corrupting the variable with multi-line text (including colons), which
# then broke YAML parsing when interpolated into install_workerpool's
# manifest ("could not find expected ':'" from ko/go-yaml).
create_workerpool_nodepool_defaults() {
  require_cmd gcloud

  log_info "machine-type=${DEFAULT_WORKERPOOL_MACHINE_TYPE} nodes=${DEFAULT_WORKERPOOL_NODE_COUNT} disk=${DEFAULT_WORKERPOOL_DISK_SIZE_GB}GB"

  if ! gcloud container node-pools create "${DEFAULT_WORKERPOOL_NODEPOOL_NAME}" \
    --cluster="${CLUSTER_NAME}" --project="${CLUSTER_PROJECT}" --location="${CLUSTER_LOCATION}" \
    --machine-type="${DEFAULT_WORKERPOOL_MACHINE_TYPE}" \
    --num-nodes="${DEFAULT_WORKERPOOL_NODE_COUNT}" \
    --disk-size="${DEFAULT_WORKERPOOL_DISK_SIZE_GB}" \
    --enable-nested-virtualization >/dev/null; then
    log_error "gcloud failed to create node pool '${DEFAULT_WORKERPOOL_NODEPOOL_NAME}'. See the error above and check your gcloud setup."
    return 1
  fi

  echo "${DEFAULT_WORKERPOOL_NODEPOOL_NAME}"
}

# print_manual_nodepool_commands
# Prints the real gcloud command a user would run by hand, pre-filled
# with the selected cluster and the same defaults
# create_workerpool_nodepool_defaults would use (still editable -- this
# is a starting point, not a locked-in choice).
print_manual_nodepool_commands() {
  cat <<EOF

  gcloud container node-pools create NODE_POOL_NAME \\
    --cluster="${CLUSTER_NAME}" \\
    --project="${CLUSTER_PROJECT}" \\
    --location="${CLUSTER_LOCATION}" \\
    --machine-type="${DEFAULT_WORKERPOOL_MACHINE_TYPE}" \\
    --num-nodes=NODE_COUNT \\
    --enable-nested-virtualization

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
      if ! WORKERPOOL_NODEPOOL_NAME="$(create_workerpool_nodepool_defaults)"; then
        log_error "Failed to create the node pool. See the error above."
        exit 1
      fi
      log_success "Created node pool: ${WORKERPOOL_NODEPOOL_NAME}"
      ;;
    "I'll run the gcloud commands myself")
      log_info "Run the following, then come back to this terminal:"
      print_manual_nodepool_commands
      if ! confirm "Have you created the node pool?" "y"; then
        log_info "Cancelled. Nothing was changed."
        exit 0
      fi
      # Re-run the real check rather than trusting a typed-in name: this
      # both confirms nested virtualization actually took (not just that
      # *a* node pool exists) and avoids a typo silently pointing later
      # steps at a pool that doesn't exist.
      if ! WORKERPOOL_NODEPOOL_NAME="$(find_virt_nodepool)"; then
        log_error "Still couldn't find a node pool with hardware virtualization enabled on ${CLUSTER_NAME}. Check that the command above succeeded, then re-run this script."
        exit 1
      fi
      log_success "Verified node pool: ${WORKERPOOL_NODEPOOL_NAME}"
      ;;
    "Cancel")
      log_info "Cancelled. Nothing was changed."
      exit 0
      ;;
  esac
}

# install_workerpool
# Applies a minimal WorkerPool CR -- no ActorTemplate/workload attached,
# deliberately not hack/install-demo-autoscaled-workerpool.sh (GKE isn't
# supported there yet: it errors outright without ATE_INSTALL_KIND) or
# hack/run-microvm-demo.sh (a bigger commitment: re-deploys the control
# plane redundantly, needs a new GCS-bucket step for micro-VM asset
# staging, and applies a specific demo actor template rather than empty
# infrastructure) -- see ONBOARDING.md step 6 for the full comparison
# that led here.
#
# sandboxClass: microvm ties this to WORKERPOOL_NODEPOOL_NAME explicitly
# via spec.template.nodeSelector on GKE's own always-present
# `cloud.google.com/gke-nodepool` label, rather than relying on the
# `ate.dev/sandboxClass=microvm` node label docs/api-guide.md mentions --
# nothing in this onboarding flow (or gcloud node-pool creation) applies
# that label, so depending on it here would be unconfirmed. The
# GKE-label nodeSelector is a real, always-true mechanism instead.
#
# Known limitation, deliberate given the "minimal manifest" scope: this
# WorkerPool won't reach Ready until a `microvm`-class SandboxConfig
# exists on the cluster, which this step does not create (that's
# hack/install-microvm-deps.sh --install, which needs its own GCS bucket
# -- out of scope here, flagged loudly to the user below instead of
# silently applying something that can't work yet).
install_workerpool() {
  ensure_docker_repo # idempotent; no-op if already set this run

  require_cmd kubectl

  local run_tool_script="${SCRIPT_DIR}/../run-tool.sh"
  if [[ ! -x "${run_tool_script}" ]]; then
    log_error "Could not find hack/run-tool.sh (expected at ${run_tool_script})."
    exit 1
  fi

  run_kubectl create namespace "${DEFAULT_WORKERPOOL_NAMESPACE}" --dry-run=client -o yaml | run_kubectl apply -f -

  # Not run_kubectl: ateomImage below is a ko:// reference that only `ko`
  # (not kubectl) knows how to build/push/resolve into a real image, the
  # same reason every hack/install-demo-*.sh script pipes into `ko apply`
  # rather than `kubectl apply`. This is a real build+push, not a quick
  # call -- deliberately not wrapped in run_kubectl's short timeout.
  cat <<EOF | KO_DOCKER_REPO="${KO_DOCKER_REPO}" "${run_tool_script}" ko apply -f - ${KUBECTL_CONTEXT:+-- --context="${KUBECTL_CONTEXT}"}
apiVersion: ate.dev/v1alpha1
kind: WorkerPool
metadata:
  name: default
  namespace: ${DEFAULT_WORKERPOOL_NAMESPACE}
spec:
  replicas: ${DEFAULT_WORKERPOOL_REPLICAS}
  ateomImage: ko://github.com/agent-substrate/substrate/cmd/ateom-microvm
  sandboxClass: microvm
  template:
    nodeSelector:
      cloud.google.com/gke-nodepool: ${WORKERPOOL_NODEPOOL_NAME}
EOF

  log_warn "The WorkerPool won't reach Ready until a 'microvm' SandboxConfig exists on the cluster (hack/install-microvm-deps.sh --install, not run by this wizard)."
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
