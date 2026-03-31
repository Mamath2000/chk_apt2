#!/usr/bin/env bash


tools::check_requirements() {
    # check required commands
    MISSING=0
    for cmd in mosquitto_pub mosquitto_sub jq apt-get apt; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Erreur: la commande '$cmd' est requise. Installez 'mosquitto-clients' et 'jq'." >&2
        MISSING=1
    fi
    done
    if [ "$MISSING" -ne 0 ]; then
    exit 1
    fi
}


tools::check_upgrades() {
  local out
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
    # escape
    pkg_esc=$(printf '%s' "$pkg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    inst_esc=$(printf '%s' "$installed" | sed 's/\\/\\\\/g; s/"/\\"/g')
    cand_esc=$(printf '%s' "$candidate" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if [ "$first" = true ]; then first=false; else printf ','; fi
    printf '{"name":"%s","installed":"%s","candidate":"%s"}' "$pkg_esc" "$inst_esc" "$cand_esc"
  done <<< "$out"
  printf ']'
}