#!/usr/bin/env bash
# Control only the DSH process managed by this checkout and DSH_BASE.
# This is a user background process, not a systemd or boot-time service.
set -euo pipefail
umask 077

DSH_BASE="${DSH_BASE:-$HOME/deepseek-harness}"
PID_FILE="$DSH_BASE/web.pid"
LOG="$DSH_BASE/logs/web.log"

running() {
  # Match the command as well as the PID to avoid stopping an unrelated process.
  [ -f "$PID_FILE" ] || return 1
  local pid=""
  read -r pid < "$PID_FILE" || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if grep -qE '^State:.*Z' "/proc/$pid/status" 2>/dev/null; then return 1; fi
  [ -r "/proc/$pid/cmdline" ] || return 1
  local command=""
  command="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
  [[ "$command" == *"$DSH_BASE/releases/"*"/app/node_modules/@deepseek-ai/dsh/lib/bin.js web"* ]]
}

show_url() {
  local url="" port=3080
  if [ -f "$LOG" ]; then
    url="$(grep -Eo 'dsh web: https?://[^[:space:]]+' "$LOG" | tail -1 | sed 's/^dsh web: //' || true)"
  fi
  [ -z "$url" ] || echo "Web URL (keep token private): $url"
  if [[ "$url" =~ ^https?://[^/:]+:([0-9]+) ]]; then port="${BASH_REMATCH[1]}"; fi
  if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    [ -z "$url" ] || echo "Windows browser (WSL localhost): ${url/127.0.0.1/localhost}"
  fi
  echo "SSH: ssh -L $port:127.0.0.1:$port $(id -un)@$(hostname -f 2>/dev/null || hostname)"
}

stop() {
  if ! running; then
    echo "[INFO] DSH is not running."
    return 0
  fi
  local pid=""
  read -r pid < "$PID_FILE"
  kill "$pid"
  for attempt in {1..15}; do
    if ! running; then
      rm -f "$PID_FILE"
      echo "[INFO] DSH stopped."
      return 0
    fi
    sleep 1
  done
  echo "[ERROR] DSH did not stop; refusing to start another process." >&2
  return 1
}

start() {
  if running; then
    echo "[INFO] DSH is already running."
    show_url
    return 0
  fi
  local release=""
  release="$(readlink -f "$DSH_BASE/current")"
  [ -f "$release/app/node_modules/@deepseek-ai/dsh/lib/bin.js" ] || { echo "[ERROR] Install DSH first." >&2; return 1; }
  mkdir -p "$DSH_BASE/logs" "$DSH_BASE/data" "$DSH_BASE/workspace"
  local pid=""
  (
    cd "$DSH_BASE/workspace"
    export DSH_HOME="$DSH_BASE/data"
    export PATH="$release/app/node_modules/.bin:$release/node/bin:$PATH"
    export npm_config_cache="$DSH_BASE/cache/npm"
    export XDG_CACHE_HOME="$DSH_BASE/cache"
    export TMPDIR="$DSH_BASE/tmp"
    exec nohup "$release/node/bin/node" "$release/app/node_modules/@deepseek-ai/dsh/lib/bin.js" web --no-open
  ) > "$LOG" 2>&1 < /dev/null 9>&- &
  pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"
  local url="" code="" deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    kill -0 "$pid" 2>/dev/null || break
    url="$(grep -Eo 'dsh web: https?://[^[:space:]]+' "$LOG" | tail -1 | sed 's/^dsh web: //' || true)"
    if [ -n "$url" ]; then
      # DSH exchanges the URL token for a cookie before redirecting to its Web page.
      code="$(curl --location --max-redirs 3 --cookie '' --connect-timeout 2 --max-time 3 --silent --output /dev/null --write-out '%{http_code}' "$url" || true)"
      if [[ "$code" == 2?? ]] && kill -0 "$pid" 2>/dev/null && ! grep -Eqi 'plugin tree failed|cannot resolve profile bundle|Failed to load plugins' "$LOG"; then
        echo "[INFO] DSH started; HTTP $code."
        show_url
        return 0
      fi
    fi
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  echo "[ERROR] DSH startup failed. See $LOG" >&2
  return 1
}

case "${1:-status}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  running) running ;;
  status)
    if running; then echo "[INFO] DSH is running (PID $(<"$PID_FILE"))."; show_url
    else echo "[INFO] DSH is not running."; exit 1; fi
    ;;
  logs) tail -n "${2:-80}" "$LOG" ;;
  -h|--help)
    cat <<'EOF'
Usage: bash dshctl.sh {start|stop|restart|status|logs [lines]}

  start     Start Web and check its authenticated HTTP response.
  stop      Stop the managed process; keep all program files and user data.
  restart   Stop, then start using the current installed release.
  status    Show process state and private access URLs (default action).
  logs      Print recent Web log lines (default: 80).

DSH_BASE must match the installation root used by install-upgrade.sh.
Default installation root: ~/deepseek-harness.
Status exits 1 when stopped. URLs and logs may contain private access tokens.
No boot-time service is configured; restart manually after WSL shutdown or reboot.
EOF
    ;;
  *) echo "[ERROR] Unknown action: $1" >&2; exit 1 ;;
esac