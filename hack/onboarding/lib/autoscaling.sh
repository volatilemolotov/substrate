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

# autoscaling.sh - configure WorkerPool HPA + capacity buffer.
#
# Runs after a virt-capable node pool exists (see workerpool.sh) and
# before the default WorkerPool is deployed. Doesn't touch the node pool
# or the WorkerPool resource itself -- just decides how (or whether)
# autoscaling gets configured.
#
# Public entry point: configure_workerpool_autoscaling
# Sets (on success): AUTOSCALING_MODE ("auto" | "manual" | "skip")

# configure_autoscaling_defaults
# TODO(kubectl): apply an HPA + capacity buffer config using the
# DEFAULT_HPA_*/DEFAULT_CAPACITY_BUFFER_SIZE values from config.sh
# against WORKERPOOL_NODEPOOL_NAME's WorkerPool, e.g. something like:
#   kubectl apply -f <rendered HPA manifest>
configure_autoscaling_defaults() {
  log_stub "configuring HPA + capacity buffer with defaults (kubectl apply)"
  log_info "min=${DEFAULT_HPA_MIN_REPLICAS} max=${DEFAULT_HPA_MAX_REPLICAS} target-cpu=${DEFAULT_HPA_TARGET_CPU_UTILIZATION}% capacity-buffer=${DEFAULT_CAPACITY_BUFFER_SIZE}"
  spinner_wait "Applying autoscaling configuration..." 1
}

# print_manual_autoscaling_commands
# TODO: print the real kubectl command(s)/manifest a user would apply by
# hand to configure HPA + capacity buffer themselves.
print_manual_autoscaling_commands() {
  cat <<EOF

  # TODO(kubectl): replace with the real command(s)/manifest.
  kubectl apply -f - <<'MANIFEST'
  apiVersion: autoscaling/v2
  kind: HorizontalPodAutoscaler
  metadata:
    name: CHANGEME
  spec:
    minReplicas: MIN_REPLICAS
    maxReplicas: MAX_REPLICAS
    # ... capacity buffer settings TBD
  MANIFEST

EOF
}

# configure_workerpool_autoscaling
# Orchestrates the three-way choice. Never exits the script -- declining
# to configure autoscaling now just means it isn't configured yet, not a
# reason to abandon the rest of onboarding.
configure_workerpool_autoscaling() {
  log_step "Configure WorkerPool HPA and capacity buffer"

  local choice
  choice="$(select_from_list "How do you want to configure autoscaling?" \
    "Configure automatically (recommended defaults)" \
    "I'll configure it manually via kubectl" \
    "Skip autoscaling")" || exit 1

  case "${choice}" in
    "Configure automatically (recommended defaults)")
      AUTOSCALING_MODE="auto"
      configure_autoscaling_defaults
      log_success "HPA and capacity buffer configured"
      ;;
    "I'll configure it manually via kubectl")
      AUTOSCALING_MODE="manual"
      log_info "Run the following whenever you're ready:"
      print_manual_autoscaling_commands
      ;;
    "Skip autoscaling")
      AUTOSCALING_MODE="skip"
      log_info "Skipping autoscaling configuration. You can configure HPA and capacity buffer later."
      ;;
  esac
}
