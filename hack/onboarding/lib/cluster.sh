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
# Public entry point: select_and_validate_cluster
# Sets (on success): CLUSTER_NAME, CLUSTER_PROJECT, CLUSTER_LOCATION, CLUSTER_VERSION

# list_clusters
# TODO(gcloud): replace with something like:
#   gcloud container clusters list --format="value(name,zone,status)"
# and merge results across the projects the user has access to (or just
# the current `gcloud config get-value project`).
#
# Prints one "name<TAB>project<TAB>location" row per cluster to stdout.
list_clusters() {
  log_stub "listing GKE clusters (gcloud container clusters list)"
  cat <<EOF
demo-cluster-a	my-gcp-project	us-central1
demo-cluster-b	my-gcp-project	us-central1-a
staging-cluster	my-other-project	europe-west4
EOF
}

# select_cluster
# Prompts the user to pick one of list_clusters' rows.
# Sets CLUSTER_NAME, CLUSTER_PROJECT, CLUSTER_LOCATION.
select_cluster() {
  local rows=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && rows+=("${line}")
  done < <(list_clusters)

  if [[ "${#rows[@]}" -eq 0 ]]; then
    log_error "No GKE clusters found. Create one first, then re-run this script."
    return 1
  fi

  local display=()
  for row in "${rows[@]}"; do
    display+=("$(echo "${row}" | awk -F'\t' '{printf "%s  (project: %s, location: %s)", $1, $2, $3}')")
  done

  local choice
  choice="$(select_from_list "Select a cluster:" "${display[@]}")" || return 1

  local index=-1
  for i in "${!display[@]}"; do
    [[ "${display[$i]}" == "${choice}" ]] && index="$i"
  done
  [[ "${index}" -ge 0 ]] || { log_error "Could not resolve selection"; return 1; }

  CLUSTER_NAME="$(echo "${rows[$index]}" | awk -F'\t' '{print $1}')"
  CLUSTER_PROJECT="$(echo "${rows[$index]}" | awk -F'\t' '{print $2}')"
  CLUSTER_LOCATION="$(echo "${rows[$index]}" | awk -F'\t' '{print $3}')"
}

# is_gke_cluster CLUSTER_NAME PROJECT LOCATION
# TODO(gcloud): `gcloud container clusters describe` succeeding is
# effectively the GKE check, since list_clusters above only lists GKE
# clusters. Kept as a separate step in case cluster selection is ever
# broadened to other sources (e.g. kubeconfig contexts) that could
# include non-GKE clusters.
is_gke_cluster() {
  log_stub "verifying cluster is GKE (gcloud container clusters describe)"
  return 0
}

# get_cluster_version CLUSTER_NAME PROJECT LOCATION
# TODO(gcloud): gcloud container clusters describe --format="value(currentMasterVersion)"
# Prints the version string to stdout.
get_cluster_version() {
  log_stub "reading cluster control plane version"
  echo "1.31.5-gke.1000"
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
  log_step "Select a cluster"
  select_cluster || exit 1
  log_success "Selected ${CLUSTER_NAME} (project: ${CLUSTER_PROJECT}, location: ${CLUSTER_LOCATION})"

  log_step "Validating cluster"
  if ! is_gke_cluster "${CLUSTER_NAME}" "${CLUSTER_PROJECT}" "${CLUSTER_LOCATION}"; then
    log_error "${CLUSTER_NAME} does not look like a GKE cluster."
    exit 1
  fi

  CLUSTER_VERSION="$(get_cluster_version "${CLUSTER_NAME}" "${CLUSTER_PROJECT}" "${CLUSTER_LOCATION}")"
  if ! check_cluster_version "${CLUSTER_VERSION}"; then
    log_error "Cluster version ${CLUSTER_VERSION} is below the minimum supported version ${MIN_GKE_VERSION}."
    exit 1
  fi
  log_success "GKE ${CLUSTER_VERSION} (>= ${MIN_GKE_VERSION} required)"
}
