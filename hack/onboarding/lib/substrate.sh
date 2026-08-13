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

# substrate.sh - detect and install the Agent Substrate control plane.
#
# Public entry point: ensure_substrate_control_plane

# is_substrate_installed
# TODO(kubectl): check for the real marker of an installed control plane,
# e.g. the ate-system namespace existing, or the WorkerPool/Actor CRDs
# being registered:
#   kubectl get ns ate-system
#   kubectl get crd workerpools.<group>
#
# Returns 0 if installed, 1 otherwise.
is_substrate_installed() {
  log_stub "checking for an existing Agent Substrate control plane (kubectl get ns ate-system)"
  [[ "${ONBOARD_STUB_SUBSTRATE_INSTALLED}" == "true" ]]
}

# install_control_plane
# TODO: this is presumably `hack/install-ate.sh --deploy-ate-system`
# pointed at the selected cluster, possibly with a curated flag set for
# the quickstart path (default ateapi-client-auth, default router, etc).
install_control_plane() {
  log_stub "installing Agent Substrate control plane (hack/install-ate.sh --deploy-ate-system)"
  spinner_wait "Deploying CRDs, atelet, ate-apiserver..." 1
  spinner_wait "Waiting for control plane pods to become ready..." 1
}

# ensure_substrate_control_plane
# Orchestrates detection + optional install. Exits the calling script if
# the control plane is missing and the user declines to install it.
ensure_substrate_control_plane() {
  log_step "Checking for Agent Substrate"
  if is_substrate_installed; then
    log_success "Agent Substrate control plane is already installed"
    return 0
  fi

  log_warn "Agent Substrate control plane was not found on ${CLUSTER_NAME}"
  if ! confirm "Install the Agent Substrate control plane now?" "y"; then
    log_info "Cancelled. Nothing was changed."
    exit 0
  fi

  log_step "Installing Agent Substrate control plane"
  install_control_plane
  log_success "Agent Substrate control plane installed"
}
