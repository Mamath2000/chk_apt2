#!/usr/bin/env bash

VERSION_FILE=""

version::init_paths() {
  local base_dir="$1"

  VERSION_FILE="$base_dir/version"
}

version::ensure_file() {
  if [ ! -f "$VERSION_FILE" ]; then
    printf '1.0.0\n' > "$VERSION_FILE"
  fi
}

version::read() {
  local current_version

  version::ensure_file
  current_version="$(head -n1 "$VERSION_FILE" | tr -d '[:space:]')"
  if [[ "$current_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$current_version"
  else
    printf '1.0.0'
  fi
}

version::write() {
  local new_version="$1"

  printf '%s\n' "$new_version" > "$VERSION_FILE"
}

version::bump_release() {
  local version_value="$1"
  local major minor patch

  if [[ "$version_value" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    patch=$((patch + 1))
    printf '%s.%s.%s' "$major" "$minor" "$patch"
  else
    printf '1.0.1'
  fi
}