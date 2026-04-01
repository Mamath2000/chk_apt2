#!/usr/bin/env bash

STATE_DIR=""
STATE_FILE=""
IN_PROGRESS_FILE=""

state::init_paths() {
  local base_dir="$1"
  STATE_DIR="$base_dir"
  STATE_FILE="$base_dir/state.json"
  IN_PROGRESS_FILE="$base_dir/.in_progress"
}

state::ensure_dir() {
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || true
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

  state::ensure_dir
  jq -n --arg v "$version" '{installed_version: $v}' > "$STATE_FILE" 2>/dev/null || printf '{"installed_version":"%s"}\n' "$version" > "$STATE_FILE"
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