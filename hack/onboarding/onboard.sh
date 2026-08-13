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

# onboard.sh - interactive Agent Substrate onboarding.
#
# This is the orchestrator only. Each step lives in hack/onboarding/lib/
# and is documented in hack/onboarding/ONBOARDING.md. Nothing in this
# tree calls real gcloud/kubectl commands yet -- see ONBOARDING.md for
# what's stubbed and how to test the flow in the meantime.

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/ui.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/cluster.sh"
source "${SCRIPT_DIR}/lib/registry.sh"
source "${SCRIPT_DIR}/lib/substrate.sh"
source "${SCRIPT_DIR}/lib/workerpool.sh"
source "${SCRIPT_DIR}/lib/autoscaling.sh"

usage() {
  cat <<EOF
Usage: $0 [options]

Interactively onboard a GKE cluster onto Agent Substrate: select a
cluster, install the control plane if missing, set up a worker node
pool, configure autoscaling, and optionally deploy the default
WorkerPool.

Options:
  -h, --help    Show this help and exit

Environment:
  ONBOARD_DISABLE_FZF=true   use the plain numbered menu instead of fzf
EOF
}

# select_install_method
# Sets INSTALL_METHOD to "quickstart" or "advanced".
select_install_method() {
  log_step "Select install method"
  local choice
  choice="$(select_from_list "How do you want to install Agent Substrate?" \
    "Quickstart" \
    "Advanced (coming soon)")" || exit 1

  case "${choice}" in
    "Quickstart")
      INSTALL_METHOD="quickstart"
      ;;
    "Advanced (coming soon)")
      log_warn "Advanced install is not available yet. Please choose Quickstart."
      exit 1
      ;;
  esac
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  print_banner "Cluster Onboarding Wizard"

  select_install_method
  select_and_validate_cluster
  ensure_substrate_control_plane
  ensure_virt_nodepool
  configure_workerpool_autoscaling
  deploy_default_workerpool

  log_success "Onboarding complete for cluster '${CLUSTER_NAME}'."
}

main "$@"
