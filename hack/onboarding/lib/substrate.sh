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
# Requires: KUBECTL_CONTEXT (set by cluster.sh's select_cluster)
# Calls into registry.sh's ensure_docker_repo on the install branch --
# see that file for why it isn't a top-level onboard.sh step itself.

# is_substrate_installed
# Checks for the ate-controller Deployment in the ate-system namespace --
# the core control-plane component hack/install-ate.sh's own
# deploy_ate_system() waits on via `rollout status` before considering
# itself done, so its presence is a reliable "is it installed" signal.
#
# Both stdout and stderr are suppressed here (unlike most other checks in
# this script), because "not found" is the expected, common outcome on a
# first run, not a failure to diagnose -- ensure_substrate_control_plane
# already treats it as a normal branch (prompt to install). A deeper
# problem (e.g. the cluster being unreachable) will still surface loudly
# the moment install_control_plane actually talks to it.
#
# Returns 0 if installed, 1 otherwise.
is_substrate_installed() {
  require_cmd kubectl
  run_kubectl get deployment ate-controller -n ate-system -o name >/dev/null 2>&1
}

# install_control_plane
# Runs the real installer, hack/install-ate.sh --deploy-ate-system,
# targeting the selected cluster via the KUBECTL_CONTEXT env var --
# install-ate.sh already reads that itself and skips its own
# `gcloud container clusters get-credentials` step when it's set (see the
# comment at the top of that script). Flags come from config.sh rather
# than being omitted and silently inheriting install-ate.sh's own
# defaults, so the Quickstart choice is visible and stays put even if
# those defaults change later.
#
# NO_DEV_ENV=true is required, not optional: install-ate.sh conditionally
# sources a developer's local .ate-dev-env.sh, which -- confirmed by
# testing against this machine's real one -- can `export KUBECTL_CONTEXT=`
# (empty), clobbering the value set below and silently falling back to
# fetching credentials for whatever cluster that dev-env file names
# instead of the one actually selected in this wizard. NO_DEV_ENV skips
# that sourcing entirely, exactly as install-ate.sh's own author designed
# it to for callers that already know their target cluster.
#
# That same skip is also why KO_DOCKER_REPO is passed explicitly here:
# .ate-dev-env.sh normally sets it, and with that file skipped, `ko`
# (which install-ate.sh uses internally to build/push images) has no
# other source for it and fails outright otherwise. KO_DOCKER_REPO must
# already be set by the caller -- see ensure_substrate_control_plane.
install_control_plane() {
  local install_script="${SCRIPT_DIR}/../install-ate.sh"
  if [[ ! -x "${install_script}" ]]; then
    log_error "Could not find hack/install-ate.sh (expected at ${install_script})."
    exit 1
  fi

  NO_DEV_ENV=true KUBECTL_CONTEXT="${KUBECTL_CONTEXT}" KO_DOCKER_REPO="${KO_DOCKER_REPO}" "${install_script}" \
    --deploy-ate-system \
    --ateapi-client-auth="${DEFAULT_ATEAPI_CLIENT_AUTH}" \
    --atenet-router="${DEFAULT_ATENET_ROUTER}"
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

  ensure_docker_repo

  log_step "Installing Agent Substrate control plane"
  install_control_plane
  log_success "Agent Substrate control plane installed"
}
