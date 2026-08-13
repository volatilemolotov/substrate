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

# cluster.sh - discover and validate the target cluster.
#
# Selection starts from the local kubeconfig (kubectl config get-contexts),
# not from listing every cluster gcloud can see -- the user's kubeconfig
# is the more direct signal of "which cluster do you mean", it can name
# GKE clusters across multiple projects, and it works the same way for
# non-GKE contexts (which just get correctly rejected in the gcloud
# verification step, rather than never being offered at all).
#
# Public entry point: select_and_validate_cluster
# Sets (on success): KUBECTL_CONTEXT, CLUSTER_NAME, CLUSTER_PROJECT,
#                     CLUSTER_LOCATION, CLUSTER_VERSION
#
# KUBECTL_CONTEXT is what any later kubectl call (substrate.sh,
# workerpool.sh once wired up) should pass via `--context=`, the same
# pattern `run_kubectl()` in hack/install-ate.sh already uses -- never
# `kubectl config use-context`, so this script doesn't mutate the user's
# global kubectl state as a side effect.

# GKE_CONTEXT_PATTERN matches the context name `gcloud container clusters
# get-credentials` writes: gke_<project>_<location>_<cluster>. None of
# those three components can contain an underscore (GCP project IDs,
# zones/regions, and GKE cluster names are all restricted to lowercase
# letters, digits, and hyphens), so splitting on "_" is unambiguous.
readonly GKE_CONTEXT_PATTERN='^gke_([a-z0-9-]+)_([a-z0-9-]+)_([a-z0-9-]+)$'

# list_kubeconfig_contexts
# Prints one kubeconfig context name per line, in kubectl's own order.
list_kubeconfig_contexts() {
  require_cmd kubectl

  local contexts
  if ! contexts="$(kubectl config get-contexts -o name)"; then
    log_error "kubectl failed to list kubeconfig contexts. See the error above and check your kubeconfig."
    return 1
  fi

  echo "${contexts}"
}

# context_display_label CONTEXT_NAME
# Best-effort human-readable label for the selection menu. Doesn't set
# any globals -- it's only for display, so a context that doesn't match
# GKE_CONTEXT_PATTERN still shows up (as its raw name) rather than being
# hidden; the real gcloud verification happens after selection.
context_display_label() {
  local context="$1"
  if [[ "${context}" =~ ${GKE_CONTEXT_PATTERN} ]]; then
    printf '%s  (project: %s, location: %s)' "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '%s' "${context}"
  fi
}

# select_cluster
# Prompts the user to pick a kubeconfig context. Sets KUBECTL_CONTEXT.
select_cluster() {
  local context_output
  if ! context_output="$(list_kubeconfig_contexts)"; then
    # list_kubeconfig_contexts already logged the specific reason.
    return 1
  fi

  local contexts=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && contexts+=("${line}")
  done <<< "${context_output}"

  if [[ "${#contexts[@]}" -eq 0 ]]; then
    log_error "No kubeconfig contexts found. Run 'gcloud container clusters get-credentials' for the cluster you want, then re-run this script."
    return 1
  fi

  local display=()
  for ctx in "${contexts[@]}"; do
    display+=("$(context_display_label "${ctx}")")
  done

  local choice
  choice="$(select_from_list "Select a kubeconfig context:" "${display[@]}")" || return 1

  local index=-1
  for i in "${!display[@]}"; do
    [[ "${display[$i]}" == "${choice}" ]] && index="$i"
  done
  [[ "${index}" -ge 0 ]] || { log_error "Could not resolve selection"; return 1; }

  KUBECTL_CONTEXT="${contexts[$index]}"
}

# parse_gke_context CONTEXT_NAME
# Authoritative parse of the selected context (as opposed to
# context_display_label's best-effort one). On success, sets
# CLUSTER_PROJECT / CLUSTER_LOCATION / CLUSTER_NAME and returns 0.
# Returns 1 if the context doesn't match GKE_CONTEXT_PATTERN.
parse_gke_context() {
  local context="$1"
  if [[ "${context}" =~ ${GKE_CONTEXT_PATTERN} ]]; then
    CLUSTER_PROJECT="${BASH_REMATCH[1]}"
    CLUSTER_LOCATION="${BASH_REMATCH[2]}"
    CLUSTER_NAME="${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

# is_gke_cluster CLUSTER_NAME PROJECT LOCATION
# The real GKE check: confirms gcloud can describe a cluster by this
# name/project/location, i.e. it actually exists and is reachable with
# current credentials -- context name alone (parse_gke_context) is just
# a naming convention, not proof.
is_gke_cluster() {
  local cluster_name="$1" project="$2" location="$3"
  gcloud container clusters describe "${cluster_name}" \
    --project="${project}" --location="${location}" \
    --format='value(name)' >/dev/null
}

# get_cluster_version CLUSTER_NAME PROJECT LOCATION
# Prints the control plane version string to stdout.
get_cluster_version() {
  local cluster_name="$1" project="$2" location="$3"
  gcloud container clusters describe "${cluster_name}" \
    --project="${project}" --location="${location}" \
    --format='value(currentMasterVersion)'
}

# version_ge A B
# Generic (non-gcloud) semver-ish comparison: returns 0 if A >= B.
# Real logic, safe to keep as-is.
version_ge() {
  local a="$1" b="$2"
  [[ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | head -n1)" == "${b}" ]]
}

# check_cluster_version VERSION
# Compares against MIN_GKE_VERSION from config.sh.
check_cluster_version() {
  local version="$1"
  # Strip the GKE-specific suffix (e.g. "-gke.1000") before comparing.
  local base_version="${version%%-*}"
  if version_ge "${base_version}" "${MIN_GKE_VERSION}"; then
    return 0
  fi
  return 1
}

# select_and_validate_cluster
# Orchestrates the steps above. Exits the calling script on failure.
select_and_validate_cluster() {
  require_cmd gcloud

  log_step "Select a cluster"
  select_cluster || exit 1
  log_success "Selected kubeconfig context: ${KUBECTL_CONTEXT}"

  log_step "Validating cluster"
  if ! parse_gke_context "${KUBECTL_CONTEXT}"; then
    log_error "Context '${KUBECTL_CONTEXT}' doesn't look like a GKE context (expected gke_<project>_<location>_<cluster>, the format 'gcloud container clusters get-credentials' writes). Select a different context."
    exit 1
  fi

  if ! is_gke_cluster "${CLUSTER_NAME}" "${CLUSTER_PROJECT}" "${CLUSTER_LOCATION}"; then
    log_error "${CLUSTER_NAME} does not look like a GKE cluster."
    exit 1
  fi

  if ! CLUSTER_VERSION="$(get_cluster_version "${CLUSTER_NAME}" "${CLUSTER_PROJECT}" "${CLUSTER_LOCATION}")"; then
    log_error "Failed to read the control plane version for ${CLUSTER_NAME}."
    exit 1
  fi
  if ! check_cluster_version "${CLUSTER_VERSION}"; then
    log_error "Cluster version ${CLUSTER_VERSION} is below the minimum supported version ${MIN_GKE_VERSION}."
    exit 1
  fi
  log_success "GKE ${CLUSTER_VERSION} (>= ${MIN_GKE_VERSION} required)"
}
