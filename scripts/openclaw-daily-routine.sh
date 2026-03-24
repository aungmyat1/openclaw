#!/bin/bash
# OpenClaw daily VM maintenance routine
# - Checks gateway runtime status, health probe, and container performance
# - Reapplies secure permissions on the mounted config dir
# - Runs a deep security audit snapshot from inside the gateway container
# - Recreates the gateway container when it is clearly unhealthy/not running
#
# Suggested systemd timer: scripts/systemd/openclaw-daily-routine.timer

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18889}"
LOG_DIR="${OPENCLAW_DAILY_LOG_DIR:-$HOME/.openclaw-maintenance}"
STATE_FILE="$LOG_DIR/daily-routine-state.env"
SUMMARY_JSON="$LOG_DIR/daily-routine-latest.json"
ALERT_FILE="$LOG_DIR/daily-routine-alert.txt"
MAX_HEALTH_WAIT_SECONDS="${OPENCLAW_DAILY_HEALTH_WAIT_SECONDS:-20}"
# How long curl may wait for /healthz (connect + response); retries help right after (re)starts.
OPENCLAW_DAILY_HEALTH_CURL_MAX_SECONDS="${OPENCLAW_DAILY_HEALTH_CURL_MAX_SECONDS:-15}"
OPENCLAW_DAILY_HEALTH_CURL_RETRIES="${OPENCLAW_DAILY_HEALTH_CURL_RETRIES:-3}"
OPENCLAW_DAILY_PERMISSION_DOCKER_TIMEOUT="${OPENCLAW_DAILY_PERMISSION_DOCKER_TIMEOUT:-90s}"
CPU_WARN_THRESHOLD="${OPENCLAW_DAILY_CPU_WARN_THRESHOLD:-200}"
MEM_WARN_THRESHOLD_MB="${OPENCLAW_DAILY_MEM_WARN_THRESHOLD_MB:-768}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/daily-routine-$(date -u +%F).log"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

have_timeout() {
  command -v timeout >/dev/null 2>&1
}

run_with_timeout() {
  local seconds="$1"
  shift
  if have_timeout; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

compose() {
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$PROJECT_DIR/docker-compose.yml" --project-directory "$PROJECT_DIR" "$@"
    return
  fi
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$PROJECT_DIR/docker-compose.yml" --project-directory "$PROJECT_DIR" "$@"
    return
  fi
  log "ERROR: neither docker-compose nor docker compose is available"
  return 1
}

container_id() {
  local id
  id="$(compose ps -q openclaw-gateway 2>/dev/null | head -n1 || true)"
  if [[ -n "$id" ]]; then
    printf '%s\n' "$id"
    return
  fi
  docker ps -aqf "name=openclaw-src_openclaw-gateway_1" | head -n1 || true
}

container_name() {
  local id
  id="$(container_id)"
  if [[ -z "$id" ]]; then
    return
  fi
  docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##'
}

fix_permissions() {
  if [[ ! -d "$CONFIG_DIR" ]]; then
    log "config dir $CONFIG_DIR does not exist yet; skipping permission repair"
    return
  fi
  log "reapplying secure permissions to $CONFIG_DIR"
  if ! run_with_timeout "$OPENCLAW_DAILY_PERMISSION_DOCKER_TIMEOUT" docker run --rm -v "$CONFIG_DIR:/mnt" alpine sh -lc '
    chmod 700 /mnt
    if [ -f /mnt/openclaw.json ]; then
      chmod 600 /mnt/openclaw.json
    fi
  ' >/dev/null 2>&1; then
    log "WARN: permission repair via alpine container failed or timed out (network/docker); continuing routine"
  fi
}

ensure_gateway_running() {
  local id status
  id="$(container_id)"
  if [[ -z "$id" ]]; then
    log "gateway container missing; creating it"
    compose up -d openclaw-gateway
    return
  fi
  status="$(docker inspect --format '{{.State.Status}}' "$id")"
  if [[ "$status" != "running" ]]; then
    log "gateway container status is $status; recreating it"
    compose up -d --force-recreate openclaw-gateway
  fi
}

wait_for_container() {
  local waited=0 id status
  while (( waited < MAX_HEALTH_WAIT_SECONDS )); do
    id="$(container_id)"
    if [[ -n "$id" ]]; then
      status="$(docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null || true)"
      if [[ "$status" == "running" ]]; then
        return 0
      fi
    fi
    sleep 1
    (( waited += 1 ))
  done
  return 1
}

http_health_code() {
  local body_file code attempt last_code=""
  local max_time="$OPENCLAW_DAILY_HEALTH_CURL_MAX_SECONDS"
  local retries="$OPENCLAW_DAILY_HEALTH_CURL_RETRIES"

  for (( attempt = 1; attempt <= retries; attempt++ )); do
    body_file="$(mktemp)"
    code="$(
      curl -sS -o "$body_file" -w '%{http_code}' \
        --connect-timeout 5 \
        --max-time "$max_time" \
        "http://127.0.0.1:${GATEWAY_PORT}/healthz" 2>/dev/null || true
    )"
    rm -f "$body_file"
    last_code="${code:-000}"
    if [[ "$last_code" != "000" && -n "$last_code" ]]; then
      printf '%s\n' "$last_code"
      return
    fi
    if (( attempt < retries )); then
      log "healthz check attempt ${attempt}/${retries} returned ${last_code:-000}; retrying in 2s"
      sleep 2
    fi
  done

  log "healthz check failed after ${retries} attempt(s); last code=${last_code:-000} port=${GATEWAY_PORT}"
  printf '%s\n' "${last_code:-000}"
}

read_container_health() {
  local id
  id="$(container_id)"
  if [[ -z "$id" ]]; then
    printf 'missing\n'
    return
  fi
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id"
}

read_container_status() {
  local id
  id="$(container_id)"
  if [[ -z "$id" ]]; then
    printf 'missing\n'
    return
  fi
  docker inspect --format '{{.State.Status}}' "$id"
}

sample_stats() {
  local name line
  name="$(container_name)"
  if [[ -z "$name" ]]; then
    printf 'missing\tmissing\n'
    return
  fi
  line="$(docker stats --no-stream --format '{{.CPUPerc}}\t{{.MemUsage}}' "$name" 2>/dev/null || true)"
  if [[ -z "$line" ]]; then
    printf 'missing\tmissing\n'
    return
  fi
  printf '%s\n' "$line"
}

parse_cpu_value() {
  printf '%s' "$1" | tr -d '%' | awk '{print ($1 == "" ? 0 : $1)}'
}

parse_mem_mb() {
  local raw
  raw="$(printf '%s' "$1" | cut -d'/' -f1 | xargs)"
  awk -v raw="$raw" '
    function lower(s) { gsub(/[A-Z]/, "", s); return tolower(raw) }
    BEGIN {
      value = raw
      unit = raw
      gsub(/[^0-9.]/, "", value)
      gsub(/[0-9.[:space:]]/, "", unit)
      unit = tolower(unit)
      num = value + 0
      if (unit == "gib" || unit == "gb") print num * 1024
      else if (unit == "mib" || unit == "mb" || unit == "") print num
      else if (unit == "kib" || unit == "kb") print num / 1024
      else print num
    }
  '
}

run_security_audit() {
  local name output_file
  name="$(container_name)"
  output_file="$LOG_DIR/security-audit-$(date -u +%Y%m%dT%H%M%SZ).log"
  if [[ -z "$name" ]]; then
    log "security audit skipped: gateway container missing"
    printf '%s\n' "$output_file"
    return
  fi
  if run_with_timeout 30s docker exec "$name" sh -lc 'node dist/index.js security audit --deep' >"$output_file" 2>&1; then
    :
  else
    log "security audit timed out or failed; captured output in $output_file"
  fi
  printf '%s\n' "$output_file"
}

maybe_recreate_gateway() {
  local reason="$1"
  log "recreating gateway: $reason"
  compose up -d --force-recreate openclaw-gateway >/dev/null
  wait_for_container || true
}

read_state_value() {
  local key="$1"
  if [[ ! -f "$STATE_FILE" ]]; then
    return
  fi
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1) }' "$STATE_FILE"
}

write_state() {
  local last_cpu="$1"
  cat >"$STATE_FILE" <<EOF
LAST_RUN_AT=$(date -u +%s)
LAST_CPU=$last_cpu
EOF
}

json_escape() {
  python3 - <<'PY' "$1"
import json, sys
print(json.dumps(sys.argv[1]))
PY
}

main() {
  local actions=()
  local gateway_status gateway_health http_code stats_line cpu_raw mem_raw cpu_value mem_value
  local audit_file critical_count warn_count summary_text last_cpu

  log "starting OpenClaw daily routine"
  fix_permissions
  actions+=("permissions")

  ensure_gateway_running
  wait_for_container || log "gateway did not report running within ${MAX_HEALTH_WAIT_SECONDS}s"

  gateway_status="$(read_container_status)"
  gateway_health="$(read_container_health)"
  http_code="$(http_health_code)"

  if [[ "$gateway_status" != "running" ]]; then
    maybe_recreate_gateway "container status=$gateway_status"
    actions+=("recreate:not-running")
    gateway_status="$(read_container_status)"
    gateway_health="$(read_container_health)"
    http_code="$(http_health_code)"
  elif [[ "$gateway_health" == "unhealthy" ]]; then
    maybe_recreate_gateway "container health=unhealthy"
    actions+=("recreate:unhealthy")
    gateway_status="$(read_container_status)"
    gateway_health="$(read_container_health)"
    http_code="$(http_health_code)"
  fi

  stats_line="$(sample_stats)"
  cpu_raw="$(printf '%s' "$stats_line" | cut -f1)"
  mem_raw="$(printf '%s' "$stats_line" | cut -f2)"
  cpu_value="$(parse_cpu_value "$cpu_raw")"
  mem_value="$(parse_mem_mb "$mem_raw")"

  if awk -v cur="$cpu_value" -v thr="$CPU_WARN_THRESHOLD" 'BEGIN { exit !(cur > thr) }'; then
    maybe_recreate_gateway "cpu=${cpu_value}% exceeds threshold=${CPU_WARN_THRESHOLD}%"
    actions+=("recreate:high-cpu")
    gateway_status="$(read_container_status)"
    gateway_health="$(read_container_health)"
    http_code="$(http_health_code)"
    stats_line="$(sample_stats)"
    cpu_raw="$(printf '%s' "$stats_line" | cut -f1)"
    mem_raw="$(printf '%s' "$stats_line" | cut -f2)"
    cpu_value="$(parse_cpu_value "$cpu_raw")"
    mem_value="$(parse_mem_mb "$mem_raw")"
  fi

  audit_file="$(run_security_audit)"
  # grep exits 2 if audit_file is missing; with pipefail that would fail the whole routine.
  if [[ -f "$audit_file" ]]; then
    critical_count="$(grep -E '^Summary:' "$audit_file" 2>/dev/null | sed -E 's/.*Summary: ([0-9]+) critical.*/\1/' | tail -n1 || true)"
    warn_count="$(grep -E '^Summary:' "$audit_file" 2>/dev/null | sed -E 's/.*critical · ([0-9]+) warn.*/\1/' | tail -n1 || true)"
  else
    critical_count="unknown"
    warn_count="unknown"
  fi
  critical_count="${critical_count:-unknown}"
  warn_count="${warn_count:-unknown}"

  last_cpu="$(read_state_value LAST_CPU)"
  if [[ "$cpu_value" != "0" && "$cpu_value" != "missing" && -n "${last_cpu:-}" ]]; then
    if awk -v cur="$cpu_value" -v prev="$last_cpu" -v thr="$CPU_WARN_THRESHOLD" 'BEGIN { exit !((cur > thr) && (prev > thr)) }'; then
      log "high CPU persisted across runs: previous=${last_cpu}% current=${cpu_value}%"
    fi
  fi

  if awk -v cur="$cpu_value" -v thr="$CPU_WARN_THRESHOLD" 'BEGIN { exit !(cur > thr) }'; then
    log "WARN: gateway CPU above threshold (${cpu_value}% > ${CPU_WARN_THRESHOLD}%)"
  fi
  if awk -v cur="$mem_value" -v thr="$MEM_WARN_THRESHOLD_MB" 'BEGIN { exit !(cur > thr) }'; then
    log "WARN: gateway memory above threshold (${mem_value} MiB > ${MEM_WARN_THRESHOLD_MB} MiB)"
  fi

  summary_text="status=${gateway_status} health=${gateway_health} http=${http_code} cpu=${cpu_raw} mem=${mem_raw} security_critical=${critical_count} security_warn=${warn_count}"
  log "summary: $summary_text"

  cat >"$SUMMARY_JSON" <<EOF
{
  "timestamp": $(json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)"),
  "gateway": {
    "status": $(json_escape "$gateway_status"),
    "health": $(json_escape "$gateway_health"),
    "httpCode": $(json_escape "$http_code")
  },
  "performance": {
    "cpu": $(json_escape "$cpu_raw"),
    "memory": $(json_escape "$mem_raw")
  },
  "security": {
    "critical": $(json_escape "$critical_count"),
    "warn": $(json_escape "$warn_count"),
    "auditLog": $(json_escape "$audit_file")
  },
  "actions": [
$(printf '    %s\n' "${actions[@]}" | sed 's/.*/"&"/' | paste -sd, -)
  ]
}
EOF

  write_state "$cpu_value"

  if [[ "$gateway_status" != "running" || "$gateway_health" == "unhealthy" || "$http_code" == "000" || "$critical_count" != "0" ]]; then
    printf '%s\n' "$summary_text" >"$ALERT_FILE"
    log "routine completed with warnings/failures; see $ALERT_FILE and $SUMMARY_JSON"
    return 1
  fi

  rm -f "$ALERT_FILE"
  log "daily routine completed successfully"
}

main "$@"
