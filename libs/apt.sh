#!/usr/bin/env bash

APT_LAST_OUTPUT=""

apt::run_update() {
  apt-get update
}

apt::run_upgrade() {
  local dry="$1"
  local autoremove="$2"
  local output_file rc

  output_file="$(mktemp)"
  rc=0

  if [ "$dry" = "true" ]; then
    if apt-get -s dist-upgrade >"$output_file" 2>&1; then
      rc=0
    else
      rc=$?
    fi
  else
    if apt-get -y dist-upgrade >"$output_file" 2>&1; then
      rc=0
    else
      rc=$?
    fi

    if [ "$rc" -eq 0 ] && [ "$autoremove" = "true" ]; then
      if apt-get -y autoremove >>"$output_file" 2>&1; then
        rc=0
      else
        rc=$?
      fi
    fi
  fi

  APT_LAST_OUTPUT="$(head -c20000 "$output_file")"
  rm -f "$output_file"
  return "$rc"
}

apt::bump_version() {
  local version="$1"

  if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local patch="${BASH_REMATCH[3]}"
    patch=$((patch + 1))
    printf '%s.%s.%s' "$major" "$minor" "$patch"
  else
    printf '1.0.1'
  fi
}

apt::check_upgrades() {
  local out line pkg candidate installed pkg_esc inst_esc cand_esc first

  out=$(apt list --upgradable 2>/dev/null || true)
  out="$(echo "$out" | sed '1d')"
  if [ -z "$(echo "$out" | tr -d '[:space:]')" ]; then
    printf '[]'
    return
  fi

  printf '['
  first=true
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    pkg=$(printf '%s' "$line" | cut -d'/' -f1)
    candidate=$(printf '%s' "$line" | awk '{print $2}')
    installed=""
    if printf '%s' "$line" | grep -q 'upgradable from:'; then
      installed=$(printf '%s' "$line" | sed -n 's/.*upgradable from: \([^]]*\).*/\1/p')
    fi
    pkg_esc=$(printf '%s' "$pkg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    inst_esc=$(printf '%s' "$installed" | sed 's/\\/\\\\/g; s/"/\\"/g')
    cand_esc=$(printf '%s' "$candidate" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if [ "$first" = true ]; then
      first=false
    else
      printf ','
    fi
    printf '{"name":"%s","installed":"%s","candidate":"%s"}' "$pkg_esc" "$inst_esc" "$cand_esc"
  done <<< "$out"
  printf ']'
}