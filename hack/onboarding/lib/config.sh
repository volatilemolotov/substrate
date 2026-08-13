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

# Defaults used when the user asks the script to create the worker node
# pool for them instead of running gcloud commands manually.
# EDITME: confirm these against docs/demos/*/README.md sizing guidance.
readonly DEFAULT_WORKERPOOL_NODEPOOL_NAME="substrate-workerpool"
readonly DEFAULT_WORKERPOOL_MACHINE_TYPE="n2-standard-8"
readonly DEFAULT_WORKERPOOL_NODE_COUNT="3"
readonly DEFAULT_WORKERPOOL_DISK_SIZE_GB="100"

# Defaults used when the user asks the script to configure HPA + capacity
# buffer automatically. "Capacity buffer" = idle/pre-warmed workers kept
# ready ahead of demand, on top of whatever the HPA target implies.
# EDITME: confirm these against docs/demos/*/README.md sizing guidance.
readonly DEFAULT_HPA_MIN_REPLICAS="2"
readonly DEFAULT_HPA_MAX_REPLICAS="10"
readonly DEFAULT_HPA_TARGET_CPU_UTILIZATION="70"
readonly DEFAULT_CAPACITY_BUFFER_SIZE="2"

# Env var toggles used only to exercise the script's control flow before
# the real gcloud/kubectl integrations exist. See ONBOARDING.md.
: "${ONBOARD_STUB_SUBSTRATE_INSTALLED:=false}"
: "${ONBOARD_STUB_VIRT_NODEPOOL_FOUND:=false}"
