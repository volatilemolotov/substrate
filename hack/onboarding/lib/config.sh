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

# config.sh - single place for the constants/defaults the onboarding
# script needs. Nothing here executes anything; it's just values.
#
# Everything marked EDITME is a placeholder guess and should be reviewed
# before this script talks to real infrastructure.

# Minimum GKE control plane version Agent Substrate supports.
# EDITME: confirm against the real support matrix.
readonly MIN_GKE_VERSION="1.30.0"

# Timeout applied to every kubectl call this script makes directly (via
# run_kubectl in ui.sh) against the API server. Discovered the hard way:
# with a stale gcloud auth token, gke-gcloud-auth-plugin can leave
# `kubectl get` hanging for minutes with zero output instead of failing
# fast the way a plain `gcloud` call does -- a quick existence check
# should never be able to stall the whole wizard like that.
readonly DEFAULT_KUBECTL_REQUEST_TIMEOUT="15s"

# Flags passed to `hack/install-ate.sh --deploy-ate-system` for the
# Quickstart path. These match that script's own defaults today; made
# explicit here (rather than just omitting the flags and inheriting
# whatever install-ate.sh currently defaults to) so the choice is visible
# and a future default change over there doesn't silently change what
# Quickstart installs.
readonly DEFAULT_ATEAPI_CLIENT_AUTH="cert"
readonly DEFAULT_ATENET_ROUTER="envoy"

# Image name suggested (never silently applied) when the user enters
# KO_DOCKER_REPO manually instead of picking an Artifact Registry repo
# via gcloud -- the full suggestion becomes gcr.io/<project>/<this>.
# EDITME.
readonly DEFAULT_KO_DOCKER_REPO_IMAGE="agent-substrate"

# Defaults used when the user asks the script to create the worker node
# pool for them instead of running gcloud commands manually.
# EDITME: confirm these against docs/demos/*/README.md sizing guidance.
readonly DEFAULT_WORKERPOOL_NODEPOOL_NAME="substrate-workerpool"
readonly DEFAULT_WORKERPOOL_MACHINE_TYPE="n2-standard-8"
readonly DEFAULT_WORKERPOOL_NODE_COUNT="3"
readonly DEFAULT_WORKERPOOL_DISK_SIZE_GB="100"

# Defaults used when the user asks the script to configure HPA
# automatically: a standard autoscaling/v2 HorizontalPodAutoscaler
# targeting the WorkerPool's /scale subresource (confirmed real --
# demos/autoscaled-workerpool/hpa-kind.yaml does exactly this, with a
# comment defining "capacity buffer" as minReplicas: a warm floor of
# workers kept ready ahead of demand. DEFAULT_HPA_MIN_REPLICAS *is* the
# capacity buffer here -- there is no separate field for it (there used
# to be a redundant DEFAULT_CAPACITY_BUFFER_SIZE constant; removed once
# this was confirmed against the real demo).
#
# Uses a plain CPU Resource metric (metrics-server, already on every GKE
# cluster) rather than the demo's custom ate_workerpool_workers external
# metric, which needs a whole self-hosted Prometheus + prometheus-adapter
# stack this onboarding flow doesn't set up -- see ONBOARDING.md step 5
# for the full reasoning and the option this deliberately didn't take.
# EDITME: confirm these against docs/demos/*/README.md sizing guidance.
readonly DEFAULT_HPA_MIN_REPLICAS="2"
readonly DEFAULT_HPA_MAX_REPLICAS="10"
readonly DEFAULT_HPA_TARGET_CPU_UTILIZATION="70"

# Namespace/replica count for the minimal default WorkerPool
# install_workerpool applies (see workerpool.sh -- a bare WorkerPool CR,
# no ActorTemplate/workload, sandboxClass: microvm). EDITME.
readonly DEFAULT_WORKERPOOL_NAMESPACE="ate-workerpool"
readonly DEFAULT_WORKERPOOL_REPLICAS="3"
