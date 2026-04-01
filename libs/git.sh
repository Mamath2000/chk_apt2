#!/usr/bin/env bash

git::require_repo() {
  local repo_dir="$1"

  git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

git::pull_repo() {
  local repo_dir="$1"

  if ! git::require_repo "$repo_dir"; then
    echo "Le répertoire n'est pas un dépôt Git: $repo_dir" >&2
    return 1
  fi

  git -C "$repo_dir" pull --ff-only
}

git::service_exists() {
  local service_name="$1"

  systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fx "$service_name" >/dev/null 2>&1
}

git::restart_service() {
  local service_name="$1"

  systemctl restart "$service_name"
}