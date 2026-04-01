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

  # essayer d'exécuter le pull en tant que propriétaire du répertoire afin
  # d'utiliser ses clés/credentials (utile quand le service tourne en root)
  local owner_user rc output
  owner_user=$(stat -c '%U' "$repo_dir" 2>/dev/null || true)

  local origin_url token auth_url set_cmd pull_cmd restore_cmd
  origin_url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)
  token="${GITHUB_TOKEN:-}"

  # Si l'origine est en HTTPS et qu'un token est fourni, utiliser une URL
  # authentifiée temporaire pour effectuer le pull (puis restaurer l'origin).
  if printf '%s' "$origin_url" | grep -q '^https://' && [ -n "$token" ]; then
    auth_url=${origin_url/https:\/\//https://x-access-token:${token}@}

    set_cmd="git -C \"$repo_dir\" remote set-url origin \"$auth_url\""
    pull_cmd="git -C \"$repo_dir\" pull --ff-only"
    restore_cmd="git -C \"$repo_dir\" remote set-url origin \"$origin_url\""

    if [ -n "$owner_user" ] && [ "$owner_user" != "root" ]; then
      if command -v runuser >/dev/null 2>&1; then
        output=$(runuser -u "$owner_user" -- sh -c "$set_cmd && $pull_cmd; rc=\$?; $restore_cmd; exit \$rc" 2>&1) || rc=$?
      elif command -v sudo >/dev/null 2>&1; then
        output=$(sudo -u "$owner_user" -- sh -c "$set_cmd && $pull_cmd; rc=\$?; $restore_cmd; exit \$rc" 2>&1) || rc=$?
      elif command -v su >/dev/null 2>&1; then
        output=$(su - "$owner_user" -s /bin/sh -c "$set_cmd && $pull_cmd; rc=\$?; $restore_cmd; exit \$rc" 2>&1) || rc=$?
      else
        output=$(sh -c "$set_cmd && $pull_cmd; rc=\$?; $restore_cmd; exit \$rc" 2>&1) || rc=$?
      fi
    else
      output=$(sh -c "$set_cmd && $pull_cmd; rc=\$?; $restore_cmd; exit \$rc" 2>&1) || rc=$?
    fi
  else
    if [ -n "$owner_user" ] && [ "$owner_user" != "root" ]; then
      if command -v runuser >/dev/null 2>&1; then
        output=$(runuser -u "$owner_user" -- git -C "$repo_dir" pull --ff-only 2>&1) || rc=$?
      elif command -v sudo >/dev/null 2>&1; then
        output=$(sudo -u "$owner_user" -- git -C "$repo_dir" pull --ff-only 2>&1) || rc=$?
      elif command -v su >/dev/null 2>&1; then
        output=$(su - "$owner_user" -s /bin/sh -c "git -C \"$repo_dir\" pull --ff-only" 2>&1) || rc=$?
      else
        output=$(git -C "$repo_dir" pull --ff-only 2>&1) || rc=$?
      fi
    else
      output=$(git -C "$repo_dir" pull --ff-only 2>&1) || rc=$?
    fi
  fi

  # renvoyer la sortie pour que l'appelant puisse la journaliser
  printf '%s' "$output"
  return ${rc:-0}
}

git::service_exists() {
  local service_name="$1"

  systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fx "$service_name" >/dev/null 2>&1
}

git::restart_service() {
  local service_name="$1"

  systemctl restart "$service_name"
}