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

# autoscaling.sh - configure WorkerPool HPA (capacity buffer = minReplicas,
# a warm floor of workers kept ready ahead of demand -- see config.sh).
#
# Runs after a virt-capable node pool exists (see workerpool.sh) and
# before the default WorkerPool is deployed (workerpool.sh's
# deploy_default_workerpool) -- so the HPA this applies necessarily
# targets a WorkerPool that doesn't exist yet. That's fine: an HPA
# doesn't require its scaleTargetRef to exist at creation time (the HPA
# controller just reports FailedGetScale until the target appears), and
# it does need to match the *name* install_workerpool will use ("default"
# in DEFAULT_WORKERPOOL_NAMESPACE, config.sh) for the two to connect once
# that step runs. If the user later declines to deploy the default
# WorkerPool (deploy_default_workerpool's own yes/no), the HPA applied
# here just stays permanently dangling -- a known, reasonable consequence
# of the two steps being independently skippable, not a bug.
#
# Public entry point: configure_workerpool_autoscaling
# Sets (on success): AUTOSCALING_MODE ("auto" | "manual" | "skip")

# autoscaling_manifest
# The real HPA manifest, shared by configure_autoscaling_defaults (which
# applies it) and print_manual_autoscaling_commands (which just prints
# it) so the two can't drift apart.
#
# CPU Resource metric, not the ate_workerpool_workers external metric
# demos/autoscaled-workerpool/hpa-kind.yaml uses: that one needs a
# self-hosted Prometheus + prometheus-adapter stack (see that demo's
# prometheus-adapter.yaml) which isn't set up anywhere in this onboarding
# flow and is a materially bigger commitment (the same shape of decision
# as install_workerpool's demo-vs-minimal choice in workerpool.sh) --
# deliberately chosen against here in favor of a CPU metric, which needs
# nothing beyond metrics-server (already on every GKE cluster).
autoscaling_manifest() {
  cat <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: default
  namespace: ${DEFAULT_WORKERPOOL_NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: ate.dev/v1alpha1
    kind: WorkerPool
    name: default
  minReplicas: ${DEFAULT_HPA_MIN_REPLICAS}
  maxReplicas: ${DEFAULT_HPA_MAX_REPLICAS}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: ${DEFAULT_HPA_TARGET_CPU_UTILIZATION}
EOF
}

# configure_autoscaling_defaults
# Applies autoscaling_manifest via kubectl (a plain k8s object -- no
# ko:// image reference, unlike the WorkerPool CR itself, so run_kubectl
# is the right tool here, not `ko apply`). Also ensures
# DEFAULT_WORKERPOOL_NAMESPACE exists first: at this point in the flow
# workerpool.sh's install_workerpool (which normally creates it) hasn't
# necessarily run yet.
configure_autoscaling_defaults() {
  require_cmd kubectl

  run_kubectl create namespace "${DEFAULT_WORKERPOOL_NAMESPACE}" --dry-run=client -o yaml | run_kubectl apply -f -
  autoscaling_manifest | run_kubectl apply -f -
}

# print_manual_autoscaling_commands
# Prints the same real manifest configure_autoscaling_defaults applies,
# for the user to review/edit and apply themselves.
print_manual_autoscaling_commands() {
  echo
  echo "  kubectl apply -f - <<'MANIFEST'"
  autoscaling_manifest | sed 's/^/  /'
  echo "  MANIFEST"
  echo
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
