# Shared functions for Simple-Split Routing Gateway

log() {
  echo "$(date '+%F %T') $1" | tee -a "$LOGFILE"
}

resolve_domains_and_apply_routes() {
  local apply_cmd="$1"
  local cache_file="$2"
  local domain_file="$3"
  local special_gw="$4"
  local interface="$5"
  local log_prefix="$6"

  mkdir -p "$(dirname "$cache_file")"
  if [[ ! -f "$domain_file" ]]; then
    log "Domain file not found: $domain_file"
    exit 1
  fi
  local tmp_cache="$(mktemp)"
  log "${log_prefix}domains from $domain_file..."
  while IFS= read -r entry; do
    entry=$(echo "$entry" | xargs)
    [[ -z "$entry" || "$entry" =~ ^# ]] && continue

    local IPs=""
    if [[ "$entry" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$entry" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
      IPs="$entry"
      log "Using direct IP or range: $entry"
    else
      log "Resolving $entry..."
      local attempt=0
      local max_attempts=3
      while [[ $attempt -lt $max_attempts ]]; do
        local dig_output; dig_output=$(dig +short A "$entry")
        local dig_status=$?
        if [[ $dig_status -ne 0 ]]; then
          log "dig failed for $entry (status $dig_status). Attempt $((attempt+1))/$max_attempts."
        elif [[ -z "$dig_output" ]]; then
          log "No answer from DNS for $entry (NXDOMAIN, SERVFAIL, or empty). Attempt $((attempt+1))/$max_attempts."
        else
          IPs=$(echo "$dig_output" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^0\.0\.0\.0$' | sort -u)
        fi
        if [[ -z "$IPs" ]]; then
          log "No valid IPs from DNS for $entry (attempt $((attempt+1))/$max_attempts). dig output: '$dig_output'"
          attempt=$((attempt + 1))
          sleep 1
        else
          break
        fi
      done
      if [[ -z "$IPs" ]]; then
        log "No valid answer from DNS for $entry after $max_attempts attempts. Skipping."
        continue
      fi
    fi

    echo "$entry:$IPs" >> "$tmp_cache"
    local valid_ip_found=false
    for ip in $IPs; do
      if [[ "$ip" == "0.0.0.0" ]]; then
        log "Skipping 0.0.0.0 for $entry"
        continue
      fi
      if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        log "${log_prefix}route to $ip for $entry"
        if ! ip route replace "$ip" via "$special_gw" dev "$interface" 2>&1 | tee -a "$LOGFILE"; then
          log "Failed to set route for $ip ($entry)"
        else
          valid_ip_found=true
        fi
      else
        log "Skipping invalid IP or range: $ip"
      fi
    done
    if ! $valid_ip_found; then
      log "No valid IPs found for $entry, skipping route."
    fi
  done < "$domain_file"
  mv "$tmp_cache" "$cache_file"
  chmod 600 "$cache_file"
}
