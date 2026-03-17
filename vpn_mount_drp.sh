#!/bin/zsh
set -euo pipefail

# ---- Konfiguration ----
DOMAIN="drpfefferle.lokal"
USER_NAME="${USER}"
VPN_TEST_HOST="192.168.115.125"
WAIT_SECONDS=180
INTERVAL_SECONDS=5
MOUNT_CONFIRM_SECONDS=30
MOUNT_RETRIES=3
VPN_IFACE_PREFIXES=("utun")
LOG_FILE="${HOME}/Library/Logs/vpn_mount_drp.log"
ERR_FILE="${HOME}/Library/Logs/vpn_mount_drp.err"
LOG_MAX_BYTES=204800
LOG_KEEP=3
STATE_DIR="${HOME}/Library/Application Support/vpn_mount_drp"
STATE_FILE="${STATE_DIR}/vpn_state"
LOCK_DIR="${STATE_DIR}/run.lock"
LOCK_PID_FILE="${LOCK_DIR}/pid"

# Share-Namen auf den Servern
SHARES_125=("privat" "AEGIDA" "Praxis")
SHARES_157=("Buchhaltung")
SHORTCUT_ROOT="${HOME}/Netzlaufwerke"
NOTIFY_ON_FAILURE=1

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

notify_user() {
  local title="$1"
  local message="$2"

  [ "${NOTIFY_ON_FAILURE}" -eq 1 ] || return 0
  [ -x "/usr/bin/osascript" ] || return 0

  /usr/bin/osascript -l JavaScript - "${title}" "${message}" <<'JXA' >/dev/null 2>&1 || true
function run(argv) {
  var app = Application.currentApplication();
  app.includeStandardAdditions = true;
  app.displayNotification(argv[1], { withTitle: argv[0] });
}
JXA
}

rotate_log_file() {
  local file_path="$1"
  local max_bytes="$2"
  local keep="$3"
  local size
  local i

  [ -f "${file_path}" ] || return 0
  size="$(wc -c < "${file_path}" | tr -d ' ')"
  [ "${size}" -ge "${max_bytes}" ] || return 0

  for ((i=keep; i>=1; i--)); do
    if [ -f "${file_path}.${i}" ]; then
      if [ "${i}" -eq "${keep}" ]; then
        rm -f "${file_path}.${i}"
      else
        mv "${file_path}.${i}" "${file_path}.$((i + 1))"
      fi
    fi
  done

  mv "${file_path}" "${file_path}.1"
  : > "${file_path}"
}

get_mount_point() {
  local smb_path="$1"
  mount | awk -v src="${smb_path}" '$1 == src && $2 == "on" { print $3; exit }'
}

get_route_interface() {
  local host="$1"
  route -n get "${host}" 2>/dev/null | awk '/interface:/ {print $2; exit}'
}

is_vpn_interface() {
  local iface="$1"
  local prefix
  for prefix in "${VPN_IFACE_PREFIXES[@]}"; do
    if [[ "${iface}" == "${prefix}"* ]]; then
      return 0
    fi
  done
  return 1
}

create_shortcut() {
  local share_name="$1"
  local mount_point="$2"
  local shortcut_path="${SHORTCUT_ROOT}/${share_name}"

  mkdir -p "${SHORTCUT_ROOT}"
  ln -sfn "${mount_point}" "${shortcut_path}"
  log "Shortcut aktualisiert: ${shortcut_path} -> ${mount_point}"
}

read_previous_state() {
  if [ -f "${STATE_FILE}" ]; then
    cat "${STATE_FILE}"
  else
    echo "unknown"
  fi
}

write_state() {
  local state="$1"
  mkdir -p "${STATE_DIR}"
  echo "${state}" > "${STATE_FILE}"
}

target_network_is_ready() {
  local route_iface
  route_iface="$(get_route_interface "${VPN_TEST_HOST}" || true)"

  if [ -z "${route_iface}" ]; then
    echo ""
    return 1
  fi

  if ! ping -c 1 -W 1000 "${VPN_TEST_HOST}" >/dev/null 2>&1; then
    echo "${route_iface}"
    return 1
  fi

  echo "${route_iface}"
  return 0
}

wait_for_target_network_ready() {
  local elapsed=0
  local route_iface

  while [ "${elapsed}" -le "${WAIT_SECONDS}" ]; do
    route_iface="$(target_network_is_ready || true)"
    if [ -n "${route_iface}" ]; then
      echo "${route_iface}"
      return 0
    fi

    sleep "${INTERVAL_SECONDS}"
    elapsed=$((elapsed + INTERVAL_SECONDS))
  done

  echo "${route_iface:-}"
  return 1
}

mount_share() {
  local server_ip="$1"
  local share_name="$2"
  local smb_path="//${DOMAIN};${USER_NAME}@${server_ip}/${share_name}"
  local smb_path_fallback="//${USER_NAME}@${server_ip}/${share_name}"
  local smb_url="smb:${smb_path}"
  local smb_url_fallback="smb:${smb_path_fallback}"
  local mount_point=""
  local retry
  local i

  mount_point="$(get_mount_point "${smb_path}" || true)"
  if [ -n "${mount_point}" ]; then
    echo "Bereits gemountet: ${server_ip}/${share_name}"
    create_shortcut "${share_name}" "${mount_point}"
    return 0
  fi

  for retry in $(seq 1 "${MOUNT_RETRIES}"); do
    log "Verbinde (${retry}/${MOUNT_RETRIES}) ${smb_url}"
    # Triggert den macOS-Login-Dialog. Passwort kann dort manuell eingegeben werden.
    open "${smb_url}" || true

    for i in $(seq 1 "${MOUNT_CONFIRM_SECONDS}"); do
      mount_point="$(get_mount_point "${smb_path}" || true)"
      if [ -n "${mount_point}" ]; then
        create_shortcut "${share_name}" "${mount_point}"
        return 0
      fi
      sleep 1
    done

    log "Fallback ohne Domain: ${smb_url_fallback}"
    open "${smb_url_fallback}" || true
    for i in $(seq 1 "${MOUNT_CONFIRM_SECONDS}"); do
      mount_point="$(get_mount_point "${smb_path}" || true)"
      if [ -n "${mount_point}" ]; then
        create_shortcut "${share_name}" "${mount_point}"
        return 0
      fi

      mount_point="$(get_mount_point "${smb_path_fallback}" || true)"
      if [ -n "${mount_point}" ]; then
        create_shortcut "${share_name}" "${mount_point}"
        return 0
      fi
      sleep 1
    done
  done

  log "Mount nicht bestaetigt: ${smb_url}"
  return 1
}

is_share_mounted() {
  local server_ip="$1"
  local share_name="$2"
  local smb_path="//${DOMAIN};${USER_NAME}@${server_ip}/${share_name}"
  local smb_path_fallback="//${USER_NAME}@${server_ip}/${share_name}"

  if [ -n "$(get_mount_point "${smb_path}" || true)" ]; then
    return 0
  fi

  if [ -n "$(get_mount_point "${smb_path_fallback}" || true)" ]; then
    return 0
  fi

  return 1
}

missing_share_count() {
  local missing=0
  local share

  for share in "${SHARES_125[@]}"; do
    if ! is_share_mounted "192.168.115.125" "${share}"; then
      missing=$((missing + 1))
    fi
  done

  for share in "${SHARES_157[@]}"; do
    if ! is_share_mounted "192.168.115.157" "${share}"; then
      missing=$((missing + 1))
    fi
  done

  echo "${missing}"
}

rotate_log_file "${LOG_FILE}" "${LOG_MAX_BYTES}" "${LOG_KEEP}"
rotate_log_file "${ERR_FILE}" "${LOG_MAX_BYTES}" "${LOG_KEEP}"

release_lock() {
  rm -f "${LOCK_PID_FILE}" 2>/dev/null || true
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}

acquire_lock() {
  local lock_pid=""

  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    echo "$$" > "${LOCK_PID_FILE}"
    return 0
  fi

  if [ -f "${LOCK_PID_FILE}" ]; then
    lock_pid="$(cat "${LOCK_PID_FILE}" 2>/dev/null || true)"
    if [ -n "${lock_pid}" ] && kill -0 "${lock_pid}" 2>/dev/null; then
      log "Ein anderer Lauf ist aktiv (PID ${lock_pid}). Beende diesen Lauf."
      return 1
    fi
  fi

  log "Stale Lock erkannt. Entferne ${LOCK_DIR} und starte neu."
  rm -rf "${LOCK_DIR}"

  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    echo "$$" > "${LOCK_PID_FILE}"
    return 0
  fi

  log "Lock konnte nicht gesetzt werden. Beende diesen Lauf."
  return 1
}

mkdir -p "${STATE_DIR}"
if ! acquire_lock; then
  exit 0
fi
trap 'release_lock' EXIT INT TERM

previous_state="$(read_previous_state)"
route_iface="$(wait_for_target_network_ready || true)"
run_reason="reconnect"
connection_type="local_or_hw_vpn"
if is_vpn_interface "${route_iface:-}"; then
  connection_type="client_vpn"
fi

if [ -z "${route_iface}" ]; then
  log "Zielnetz 192.168.115.x nicht erreichbar (Interface: ${route_iface:-none}). Merke Zustand: net_down."
  write_state "net_down"
  exit 0
fi

if [ "${previous_state}" = "vpn_up" ] || [ "${previous_state}" = "net_up" ]; then
  missing_shares="$(missing_share_count)"
  if [ "${missing_shares}" -eq 0 ]; then
    log "Netzzugriff bleibt aktiv ueber ${route_iface} (${connection_type}). Kein Reconnect erkannt, kein Mount-Lauf."
    exit 0
  fi

  run_reason="recovery"
  log "Netzzugriff aktiv ueber ${route_iface} (${connection_type}), aber ${missing_shares} Share(s) fehlen. Starte Recovery-Mount."
fi

if [ "${run_reason}" = "reconnect" ]; then
  log "Netzzugriff erkannt (${previous_state} -> net_up) ueber ${route_iface} (${connection_type}). Starte Mount ..."
else
  log "Recovery-Mount gestartet ueber ${route_iface} (${connection_type})."
fi
mount_failures=0
failed_shares=()
for share in "${SHARES_125[@]}"; do
  if ! mount_share "192.168.115.125" "${share}"; then
    mount_failures=$((mount_failures + 1))
    failed_shares+=("192.168.115.125/${share}")
  fi
done

for share in "${SHARES_157[@]}"; do
  if ! mount_share "192.168.115.157" "${share}"; then
    mount_failures=$((mount_failures + 1))
    failed_shares+=("192.168.115.157/${share}")
  fi
done

if [ "${mount_failures}" -gt 0 ]; then
  failed_text="${(j:, :)failed_shares}"
  log "Mount-Lauf beendet mit ${mount_failures} Fehler(n): ${failed_text}"
  notify_user "VPN-Mount Fehler" "${mount_failures} Share(s) fehlgeschlagen: ${failed_text}"
  exit 1
fi

write_state "net_up"
log "Fertig."
