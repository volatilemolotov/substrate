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

# registry.sh - determine KO_DOCKER_REPO, the container registry `ko`
# publishes images to (needed by both hack/install-ate.sh and the `ko
# apply` workerpool.sh's install_workerpool runs directly).
#
# Why this exists: a developer's local .ate-dev-env.sh normally sets
# KO_DOCKER_REPO, but substrate.sh's install_control_plane deliberately
# passes NO_DEV_ENV=true to hack/install-ate.sh (see the comment there --
# that file can otherwise silently redirect an install to the wrong
# cluster). Skipping it means KO_DOCKER_REPO is no longer set from
# anywhere, and `ko` fails outright ("KO_DOCKER_REPO environment variable
# is unset") the moment anything tries to publish an image. This step is
# this script's replacement for that one variable.
#
# Not a top-level onboard.sh step: called from substrate.sh's
# ensure_substrate_control_plane (only on the branch that's actually
# about to install something) and from workerpool.sh's
# install_workerpool. Both calls are idempotent (see ensure_docker_repo)
# so the user is asked at most once per run, whichever step hits it
# first -- asking unconditionally as its own top-level onboard.sh step
# would mean asking about a docker registry even when nothing in the run
# ends up building or pushing anything. See the "Conventions" section of
# ONBOARDING.md for why this is a deliberate exception to "onboard.sh
# calls every step directly."
#
# Public entry point: ensure_docker_repo
# Requires: CLUSTER_PROJECT (set by cluster.sh)
# Sets (on success): KO_DOCKER_REPO

# ARTIFACT_REGISTRY_NAME_PATTERN matches the resource name
# `gcloud artifacts repositories list` returns via --format=json, e.g.
# "projects/my-project/locations/us-central1/repositories/my-repo".
readonly ARTIFACT_REGISTRY_NAME_PATTERN='^projects/[^/]+/locations/([^/]+)/repositories/([^/]+)$'

# list_artifact_registry_repos
# `gcloud artifacts repositories list`, filtered to Docker-format repos,
# scoped to CLUSTER_PROJECT. Prints one full resource name per line
# (projects/P/locations/L/repositories/R) -- see
# ARTIFACT_REGISTRY_NAME_PATTERN.
#
# Deliberately --format=json piped through `jq -r '.[].name'`, not
# --format='value(name)'. Confirmed against a live call: the two are NOT
# equivalent for this resource -- gcloud's value()/table() formatters
# apply a display transform to `name` for `artifacts repositories list`
# specifically, silently shortening it to just the repository ID
# (`my-repo`) instead of the full path. That transform is what produced
# an empty "(location: )" in the selection menu before this was fixed:
# there never was a separate `location` field to request (--format=json
# confirms the raw resource has no such field, only `name`/`format`/
# `mode`/etc.) -- `value(name)` just wasn't the untransformed name it
# looked like. --format=json is the one format gcloud won't apply that
# transform to. jq is already a dependency elsewhere in hack/ (see
# install-ate.sh, install-demo-claude-code-multiplex.sh).
list_artifact_registry_repos() {
  require_cmd gcloud
  require_cmd jq

  local json
  if ! json="$(gcloud artifacts repositories list \
    --project="${CLUSTER_PROJECT}" \
    --filter='format=DOCKER' \
    --format=json)"; then
    log_error "gcloud failed to list Artifact Registry repositories for project '${CLUSTER_PROJECT}'. See the error above and check your gcloud setup."
    return 1
  fi

  echo "${json}" | jq -r '.[].name'
}

# select_artifact_registry_repo
# Prompts the user to pick a repo from list_artifact_registry_repos.
# Sets KO_DOCKER_REPO to LOCATION-docker.pkg.dev/PROJECT/REPO_NAME, the
# host form ko/docker expect (as opposed to the repo's own
# projects/.../repositories/... resource name).
select_artifact_registry_repo() {
  local names_output
  if ! names_output="$(list_artifact_registry_repos)"; then
    # list_artifact_registry_repos already logged the specific reason.
    return 1
  fi

  local names=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && names+=("${line}")
  done <<< "${names_output}"

  if [[ "${#names[@]}" -eq 0 ]]; then
    log_error "No Docker-format Artifact Registry repositories found in project '${CLUSTER_PROJECT}'."
    return 1
  fi

  local display=()
  local location repo_name
  for full_name in "${names[@]}"; do
    if [[ "${full_name}" =~ ${ARTIFACT_REGISTRY_NAME_PATTERN} ]]; then
      display+=("${BASH_REMATCH[2]}  (location: ${BASH_REMATCH[1]})")
    else
      # Unexpected shape -- show the raw name rather than hiding the repo.
      display+=("${full_name}")
    fi
  done

  local choice
  choice="$(select_from_list "Select an Artifact Registry repository:" "${display[@]}")" || return 1

  local index=-1
  for i in "${!display[@]}"; do
    [[ "${display[$i]}" == "${choice}" ]] && index="$i"
  done
  [[ "${index}" -ge 0 ]] || { log_error "Could not resolve selection"; return 1; }

  local full_name="${names[$index]}"
  if [[ ! "${full_name}" =~ ${ARTIFACT_REGISTRY_NAME_PATTERN} ]]; then
    log_error "Could not parse Artifact Registry repository name '${full_name}' (expected projects/.../locations/.../repositories/...)."
    return 1
  fi
  location="${BASH_REMATCH[1]}"
  repo_name="${BASH_REMATCH[2]}"

  KO_DOCKER_REPO="${location}-docker.pkg.dev/${CLUSTER_PROJECT}/${repo_name}"
}

# manual_docker_repo
# Prompts for a KO_DOCKER_REPO value directly, pre-filled with a guessed
# default (gcr.io/<project>/<DEFAULT_KO_DOCKER_REPO_IMAGE>) so accepting
# it is a single keystroke -- but nothing is applied without the user
# seeing and confirming it first.
manual_docker_repo() {
  local default="gcr.io/${CLUSTER_PROJECT}/${DEFAULT_KO_DOCKER_REPO_IMAGE}"
  local input
  read -r -p "$(echo -e "${COLOR_CYAN}?${COLOR_RESET} KO_DOCKER_REPO [${default}]: ")" input
  KO_DOCKER_REPO="${input:-${default}}"
}

# ensure_docker_repo
# Orchestrates the select-vs-manual choice. Falling back to manual entry
# when the gcloud path fails isn't "fixing" the gcloud problem -- it's
# offering the exact same alternative already sitting in the menu, so it
# doesn't conflict with this script's "don't guess at gcloud/kubectl
# failures" convention (the real error is still shown, uncaptured, before
# the fallback kicks in).
#
# Idempotent: a no-op if KO_DOCKER_REPO is already set. Needed because
# this isn't only called from install_control_plane's branch anymore --
# install_workerpool (workerpool.sh) also needs KO_DOCKER_REPO for its
# own `ko apply`, and can run in the same session even when the control
# plane was already installed (so install_control_plane, and this
# function, never ran this session at all).
ensure_docker_repo() {
  if [[ -n "${KO_DOCKER_REPO:-}" ]]; then
    log_info "Reusing already-configured KO_DOCKER_REPO=${KO_DOCKER_REPO}"
    return 0
  fi

  log_step "Configure container image registry (KO_DOCKER_REPO)"

  local choice
  choice="$(select_from_list "How do you want to set the container image registry ko publishes to?" \
    "Select an Artifact Registry repository via gcloud" \
    "Enter it manually")" || exit 1

  case "${choice}" in
    "Select an Artifact Registry repository via gcloud")
      if ! select_artifact_registry_repo; then
        log_warn "Falling back to manual entry."
        manual_docker_repo
      fi
      ;;
    "Enter it manually")
      manual_docker_repo
      ;;
  esac

  log_success "Using KO_DOCKER_REPO=${KO_DOCKER_REPO}"
}
