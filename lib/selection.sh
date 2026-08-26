#!/usr/bin/env bash
# Persist / restore the selected flash drive (one drive per app instance).

set -euo pipefail

# Default state file (override with FLASH_TEST_STATE_FILE or --state-file).
selection_default_path() {
  local root="${FLASH_TEST_ROOT:-.}"
  mkdir -p "$root/state"
  echo "$root/state/selected.conf"
}

selection_path() {
  echo "${FLASH_TEST_STATE_FILE:-$(selection_default_path)}"
}

# Save selection from a metadata line.
# meta: by_id|resolved|serial|vendor|model|size_b|size_h|usb|uuid
selection_save() {
  local meta="$1"
  local path
  path="$(selection_path)"
  mkdir -p "$(dirname "$path")"

  local by_id resolved serial vendor model size_b size_h usb uuid
  IFS='|' read -r by_id resolved serial vendor model size_b size_h usb uuid <<<"$meta"

  cat >"$path" <<EOF
# flash-test saved drive selection — do not edit while a test is running
by_id=$by_id
resolved=$resolved
serial=$serial
uuid=$uuid
vendor=$vendor
model=$model
size=$size_h
usb=$usb
saved_at=$(date -Iseconds)
EOF
}

# Load selection into nameref-friendly globals / prints key=value
selection_load() {
  local path
  path="$(selection_path)"
  [[ -f "$path" ]] || return 1
  # shellcheck disable=SC1090
  # Parse safely
  local line key val
  SELECTION_BY_ID=""
  SELECTION_RESOLVED=""
  SELECTION_SERIAL=""
  SELECTION_UUID=""
  SELECTION_VENDOR=""
  SELECTION_MODEL=""
  SELECTION_SIZE=""
  SELECTION_USB=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      by_id) SELECTION_BY_ID="$val" ;;
      resolved) SELECTION_RESOLVED="$val" ;;
      serial) SELECTION_SERIAL="$val" ;;
      uuid) SELECTION_UUID="$val" ;;
      vendor) SELECTION_VENDOR="$val" ;;
      model) SELECTION_MODEL="$val" ;;
      size) SELECTION_SIZE="$val" ;;
      usb) SELECTION_USB="$val" ;;
    esac
  done <"$path"
  [[ -n "$SELECTION_BY_ID" || -n "$SELECTION_UUID" ]]
}

selection_clear() {
  local path
  path="$(selection_path)"
  rm -f "$path"
}

# Print a short banner of the saved / current selection.
selection_print() {
  local label="${1:-Selected}"
  if selection_load 2>/dev/null; then
    echo "$label UUID: ${SELECTION_UUID:-unknown}"
    echo "         serial: ${SELECTION_SERIAL:-?}  device: ${SELECTION_RESOLVED:-?}  by-id: ${SELECTION_BY_ID:-?}"
    echo "         ${SELECTION_VENDOR:-} ${SELECTION_MODEL:-}  ${SELECTION_SIZE:-}  ${SELECTION_USB:-}"
    echo "         state: $(selection_path)"
  else
    echo "$label: (none saved)"
  fi
}
