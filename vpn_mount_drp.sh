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

# Share-Namen auf den Servern
SHARES_125=("privat" "AEGIDA" "Praxis")
SHARES_157=("Buchhaltung")
SHORTCUT_ROOT="${HOME}/Netzlaufwerke"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
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

vpn_is_ready() {
  local route_iface
  route_iface="$(get_route_interface "${VPN_TEST_HOST}" || true)"

  if [ -z "${route_iface}" ]; then
    echo ""
    return 1
  fi

  if ! is_vpn_interface "${route_iface}"; then
    echo "${route_iface}"
    return 1
  fi

  if ! ping -c 1 -W 1000 "${VPN_TEST_HOST}" >/dev/null 2>&1; then
    echo "${route_iface}"
    return 1
  fi

  echo "${route_iface}"
  return 0
}

wait_for_vpn_ready() {
  local elapsed=0
  local route_iface

  while [ "${elapsed}" -le "${WAIT_SECONDS}" ]; do
    route_iface="$(vpn_is_ready || true)"
    if [ -n "${route_iface}" ] && is_vpn_interface "${route_iface}"; then
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

rotate_log_file "${LOG_FILE}" "${LOG_MAX_BYTES}" "${LOG_KEEP}"
rotate_log_file "${ERR_FILE}" "${LOG_MAX_BYTES}" "${LOG_KEEP}"

mkdir -p "${STATE_DIR}"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  log "Ein anderer Lauf ist aktiv. Beende diesen Lauf."
  exit 0
fi
trap 'rmdir "${LOCK_DIR}" 2>/dev/null || true' EXIT

previous_state="$(read_previous_state)"
route_iface="$(wait_for_vpn_ready || true)"

if [ -z "${route_iface}" ] || ! is_vpn_interface "${route_iface}"; then
  log "VPN nicht bereit (Interface: ${route_iface:-none}). Merke Zustand: vpn_down."
  write_state "vpn_down"
  exit 0
fi

if [ "${previous_state}" = "vpn_up" ]; then
  log "VPN ist weiter aktiv ueber ${route_iface}. Kein Reconnect erkannt, kein Mount-Lauf."
  exit 0
fi

log "VPN-Reconnect erkannt (${previous_state} -> vpn_up) ueber ${route_iface}. Starte Mount ..."
mount_failures=0
for share in "${SHARES_125[@]}"; do
  if ! mount_share "192.168.115.125" "${share}"; then
    mount_failures=$((mount_failures + 1))
  fi
done

for share in "${SHARES_157[@]}"; do
  if ! mount_share "192.168.115.157" "${share}"; then
    mount_failures=$((mount_failures + 1))
  fi
done

if [ "${mount_failures}" -gt 0 ]; then
  log "Mount-Lauf beendet mit ${mount_failures} Fehler(n)."
  exit 1
fi

write_state "vpn_up"
log "Fertig."
