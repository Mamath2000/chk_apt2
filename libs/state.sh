#!/usr/bin/env bash

STATE_DIR=""
STATE_FILE=""
IN_PROGRESS_FILE=""

state::init_paths() {
  local base_dir="$1"
  local namespace="${2:-}"

  STATE_DIR="$base_dir"

  if [ -n "$namespace" ]; then
    STATE_FILE="$base_dir/${namespace}_state.json"
    IN_PROGRESS_FILE="$base_dir/.${namespace}_in_progress"
  else
    STATE_FILE="$base_dir/state.json"
    IN_PROGRESS_FILE="$base_dir/.in_progress"
  fi
}

state::ensure_dir() {
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || true
}

state::read_json() {
  if [ -r "$STATE_FILE" ]; then
    jq -c '.' "$STATE_FILE" 2>/dev/null || printf '{}'
  else
    printf '{}'
  fi
}

state::write_json() {
  local json="$1"

  state::ensure_dir
  printf '%s\n' "$json" > "$STATE_FILE"
}

state::read_installed_version() {
  local installed_version="1.0.0"
  local version

  if [ -r "$STATE_FILE" ]; then
    version=$(jq -r '.installed_version // empty' "$STATE_FILE" 2>/dev/null || true)
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      installed_version="$version"
    fi
  else
    state::ensure_dir
    printf '{"installed_version":"%s"}\n' "$installed_version" > "$STATE_FILE" 2>/dev/null || true
  fi

  printf '%s' "$installed_version"
}

state::write_installed_version() {
  local version="$1"
  local json

  json="$(state::read_json | jq -c --arg v "$version" '.installed_version = $v')"
  state::write_json "$json"
}

state::ensure_docker_stack() {
  local stack_id="$1"
  local deployed_images_json="${2:-"{}"}"
  local json

  json="$(state::read_json | jq -c --arg id "$stack_id" --arg version "1.0.0" --argjson images "$deployed_images_json" '
    .docker = (.docker // {})
    | .docker[$id] = ({installed_version: $version, deployed_images: $images, in_progress: false} + (.docker[$id] // {}))
  ')"
  state::write_json "$json"
}

state::read_docker_installed_version() {
  local stack_id="$1"
  local installed_version="1.0.0"
  local version

  version="$(state::read_json | jq -r --arg id "$stack_id" '.docker[$id].installed_version // empty')"
  if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    installed_version="$version"
  fi

  printf '%s' "$installed_version"
}

state::write_docker_installed_version() {
  local stack_id="$1"
  local version="$2"
  local json

  json="$(state::read_json | jq -c --arg id "$stack_id" --arg version "$version" '
    .docker = (.docker // {})
    | .docker[$id] = ((.docker[$id] // {}) + {installed_version: $version})
  ')"
  state::write_json "$json"
}

state::read_docker_deployed_images() {
  local stack_id="$1"
  state::read_json | jq -c --arg id "$stack_id" '.docker[$id].deployed_images // {}'
}

state::write_docker_deployed_images() {
  local stack_id="$1"
  local deployed_images_json="$2"
  local json

  json="$(state::read_json | jq -c --arg id "$stack_id" --argjson images "$deployed_images_json" '
    .docker = (.docker // {})
    | .docker[$id] = ((.docker[$id] // {}) + {deployed_images: $images})
  ')"
  state::write_json "$json"
}

state::mark_docker_stack_in_progress() {
  local stack_id="$1"
  local json

  json="$(state::read_json | jq -c --arg id "$stack_id" '
    .docker = (.docker // {})
    | .docker[$id] = ((.docker[$id] // {}) + {in_progress: true})
  ')"
  state::write_json "$json"
}

state::clear_docker_stack_in_progress() {
  local stack_id="$1"
  local json

  json="$(state::read_json | jq -c --arg id "$stack_id" '
    .docker = (.docker // {})
    | .docker[$id] = ((.docker[$id] // {}) + {in_progress: false})
  ')"
  state::write_json "$json"
}

state::is_docker_stack_in_progress() {
  local stack_id="$1"

  if [ "$(state::read_json | jq -r --arg id "$stack_id" '.docker[$id].in_progress // false')" = "true" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

state::clear_all_docker_stack_in_progress() {
  local json

  json="$(state::read_json | jq -c '
    .docker = ((.docker // {}) | with_entries(.value = (.value + {in_progress: false})))
  ')"
  state::write_json "$json"
}

state::mark_in_progress() {
  state::ensure_dir
  : > "$IN_PROGRESS_FILE"
}

state::clear_in_progress() {
  [ -n "$IN_PROGRESS_FILE" ] && rm -f "$IN_PROGRESS_FILE"
}

state::is_in_progress() {
  if [ -n "$IN_PROGRESS_FILE" ] && [ -f "$IN_PROGRESS_FILE" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}