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

# ui.sh - generic terminal UI helpers (logging, prompts, menus).
#
# Nothing in this file talks to gcloud/kubectl. It only knows how to print
# and how to ask the user questions, so it can be reused by any step.

# --- Colors -------------------------------------------------------------

COLOR_CYAN='\033[1;36m'
COLOR_GREEN='\033[1;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[1;31m'
COLOR_RESET='\033[0m'

# --- Banner ---------------------------------------------------------------

# print_banner [SUBTITLE]
# Big boxed "AGENT SUBSTRATE" header shown once at script start. Width and
# centering are computed so the box can't go out of alignment if the
# title/subtitle text changes.
print_banner() {
  local subtitle="${1:-}"
  local title="AGENT SUBSTRATE"
  local width=59

  # tr can't be used to repeat '─' here: it's multi-byte UTF-8 and tr
  # substitutes byte-for-byte in the C locale, which corrupts it. Repeat
  # it via printf's format-reuse instead (%.0s consumes an arg but
  # prints none of it, so the literal before it is what repeats).
  _banner_rule() {
    local ch="$1" i rule=""
    for ((i = 0; i < width; i++)); do rule+="${ch}"; done
    echo "${rule}"
  }

  _banner_line() {
    local text="$1"
    local pad=$(( width - ${#text} ))
    local left=$(( pad / 2 ))
    local right=$(( pad - left ))
    printf '│%*s%s%*s│\n' "${left}" "" "${text}" "${right}" ""
  }

  echo -e "${COLOR_CYAN}"
  echo "┌$(_banner_rule '─')┐"
  _banner_line ""
  _banner_line "${title}"
  [[ -n "${subtitle}" ]] && { _banner_line ""; _banner_line "${subtitle}"; }
  _banner_line ""
  echo "└$(_banner_rule '─')┘"
  echo -e "${COLOR_RESET}"

  unset -f _banner_rule

  unset -f _banner_line
}

# --- Logging --------------------------------------------------------------
#
# All logging goes to stderr, never stdout. Several functions in the lib/
# modules return their actual result by echoing to stdout and are called
# via command substitution (e.g. `name="$(list_kubeconfig_contexts)"`); if a log
# helper wrote to stdout, its text would silently become part of that
# return value. Keep it this way even though a few call sites don't
# currently capture output, so it's never a landmine when they start to.

log_step() {
  echo -e "${COLOR_CYAN}==> $*${COLOR_RESET}" >&2
}

log_info() {
  echo -e "    $*" >&2
}

log_success() {
  echo -e "${COLOR_GREEN}✔ $*${COLOR_RESET}" >&2
}

log_warn() {
  echo -e "${COLOR_YELLOW}! $*${COLOR_RESET}" >&2
}

log_error() {
  echo -e "${COLOR_RED}✘ $*${COLOR_RESET}" >&2
}

# log_stub marks output that comes from a not-yet-implemented integration
# (gcloud/kubectl calls). Grep for STUB to find everything left to wire up.
log_stub() {
  echo -e "    ${COLOR_YELLOW}[STUB]${COLOR_RESET} $*" >&2
}

# --- Prompts ----------------------------------------------------------

# confirm PROMPT [default:y|n]
# Returns 0 for yes, 1 for no.
confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local suffix="[y/N]"
  [[ "${default}" == "y" ]] && suffix="[Y/n]"

  local reply
  read -r -p "$(echo -e "${COLOR_CYAN}?${COLOR_RESET} ${prompt} ${suffix} ")" reply
  reply="${reply:-${default}}"
  [[ "${reply}" =~ ^([yY][eE][sS]|[yY])$ ]]
}

# select_from_list PROMPT ITEM [ITEM...]
# Prints the chosen item to stdout (only). Everything else goes to stderr,
# so callers should use: choice="$(select_from_list "..." "${items[@]}")"
#
# Uses fzf when available for a nicer experience, falls back to the
# builtin `select` menu otherwise.
select_from_list() {
  local prompt="$1"
  shift
  local items=("$@")

  if [[ "${#items[@]}" -eq 0 ]]; then
    log_error "select_from_list: no items to choose from" >&2
    return 1
  fi

  if [[ "${ONBOARD_DISABLE_FZF:-false}" != "true" ]] && command -v fzf >/dev/null 2>&1; then
    local choice
    choice="$(printf '%s\n' "${items[@]}" | fzf --prompt="${prompt} " --height=~40% --border --reverse)"
    if [[ -z "${choice}" ]]; then
      log_warn "No selection made" >&2
      return 1
    fi
    echo "${choice}"
    return 0
  fi

  echo -e "${COLOR_CYAN}?${COLOR_RESET} ${prompt}" >&2
  local PS3="Enter number: "
  local choice
  select choice in "${items[@]}"; do
    if [[ -n "${choice}" ]]; then
      echo "${choice}"
      return 0
    fi
    echo "Invalid selection, try again." >&2
  done
}

# require_cmd NAME [HINT]
# Exits with a clear error if NAME isn't on PATH. Meant for the top of
# any function that's about to shell out to an external tool (gcloud,
# kubectl, ...).
require_cmd() {
  local name="$1" hint="${2:-}"
  if ! command -v "${name}" >/dev/null 2>&1; then
    log_error "'${name}' is required but was not found on PATH.${hint:+ ${hint}}"
    exit 1
  fi
}

# run_kubectl ARGS...
# Wraps kubectl with --context=$KUBECTL_CONTEXT when it's set (cluster.sh
# sets it after cluster selection), then forwards to kubectl. The
# --context part mirrors run_kubectl() in hack/install-ate.sh exactly, so
# every kubectl call in this script targets the selected cluster
# explicitly instead of relying on -- and never needing to change --
# whatever kubeconfig's current-context happens to be.
#
# The whole call is wrapped in the external `timeout` command (GNU
# coreutils; this repo already assumes a Linux dev environment, see
# other hack/ scripts), not just kubectl's own --request-timeout flag.
# Discovered the hard way: with a stale gcloud auth token,
# gke-gcloud-auth-plugin can hang trying to obtain a token *before*
# kubectl ever issues the request that --request-timeout would bound --
# --request-timeout is kept too, belt and suspenders, but `timeout` is
# what actually guarantees this can't stall the wizard indefinitely.
run_kubectl() {
  timeout "${DEFAULT_KUBECTL_REQUEST_TIMEOUT}" kubectl \
    ${KUBECTL_CONTEXT:+--context=${KUBECTL_CONTEXT}} \
    --request-timeout="${DEFAULT_KUBECTL_REQUEST_TIMEOUT}" \
    "$@"
}

# spinner_wait MESSAGE SECONDS
# Cheap stand-in for "do work and show progress" until real long-running
# gcloud/kubectl calls are wired in.
spinner_wait() {
  local message="$1"
  local seconds="${2:-1}"
  log_info "${message}"
  sleep "${seconds}"
}
