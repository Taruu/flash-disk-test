#!/usr/bin/env bash
# Hardware enumeration and metadata extraction.

set -euo pipefail

# Human-readable size from bytes
_human_size() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    split("B KB MB GB TB", u, " ")
    s=b+0
    i=1
    while (s >= 1024 && i < 5) { s/=1024; i++ }
    if (i==1) printf "%d%s", s, u[i]
    else printf "%.1f%s", s, u[i]
  }'
}

# Query a single udev property
_udev_prop() {
  local dev="$1" key="$2"
  udevadm info --query=property --name="$dev" 2>/dev/null \
    | grep -E "^${key}=" | head -n1 | cut -d= -f2- || true
}

# Best-effort USB speed string
_usb_speed() {
  local dev="$1"
  local speed id_bus
  id_bus="$(_udev_prop "$dev" ID_BUS)"
  if [[ "$id_bus" != "usb" ]]; then
    # loop or other
    if [[ "$(basename "$(realpath -e "$dev")")" == loop* ]]; then
      echo "loop"
      return 0
    fi
    echo "${id_bus:-unknown}"
    return 0
  fi
  speed="$(_udev_prop "$dev" ID_USB_SPEED)"
  if [[ -z "$speed" ]]; then
    # Fallback: walk sysfs
    local sys
    sys="$(udevadm info -q path -n "$dev" 2>/dev/null || true)"
    if [[ -n "$sys" && -r "/sys${sys}/../speed" ]]; then
      speed="$(cat "/sys${sys}/../speed" 2>/dev/null || true)"
    elif [[ -n "$sys" ]]; then
      local d="/sys${sys}"
      while [[ "$d" != "/sys" && ! -r "$d/speed" ]]; do
        d="$(dirname "$d")"
      done
      [[ -r "$d/speed" ]] && speed="$(cat "$d/speed" 2>/dev/null || true)"
    fi
  fi
  case "$speed" in
    12000*|10000*|5000*) echo "USB3" ;;
    480*) echo "USB2" ;;
    12*) echo "USB1" ;;
    "") echo "USB" ;;
    *) echo "USB(${speed})" ;;
  esac
}

# Collect metadata for one device. Prints pipe-delimited fields:
# by_id|resolved|serial|vendor|model|size_bytes|size_human|usb_speed
collect_device_metadata() {
  local dev="$1"
  local allow_loop="${2:-0}"
  local by_id resolved serial vendor model size_b size_h usb

  if ! validate_target_device "$dev" "$allow_loop"; then
    return 1
  fi

  by_id="$(pin_device_by_id "$dev")" || return 1
  resolved="$(realpath -e "$by_id")"
  serial="$(_udev_prop "$resolved" ID_SERIAL_SHORT)"
  if [[ -z "$serial" ]]; then
    serial="$(_udev_prop "$resolved" ID_SERIAL)"
  fi
  if [[ -z "$serial" ]]; then
    serial="$(basename "$by_id" | tr '/' '_')"
  fi
  vendor="$(_udev_prop "$resolved" ID_VENDOR)"
  [[ -z "$vendor" ]] && vendor="$(_udev_prop "$resolved" ID_VENDOR_FROM_DATABASE)"
  model="$(_udev_prop "$resolved" ID_MODEL)"
  [[ -z "$model" ]] && model="$(_udev_prop "$resolved" ID_MODEL_FROM_DATABASE)"
  vendor="${vendor:-unknown}"
  model="${model:-unknown}"
  size_b="$(lsblk -b -dn -o SIZE "$resolved" 2>/dev/null | tr -d '[:space:]')"
  size_b="${size_b:-0}"
  size_h="$(_human_size "$size_b")"
  usb="$(_usb_speed "$resolved")"

  # Sanitize for pipe-delimited output
  serial="${serial//|/}"
  vendor="${vendor//|/}"
  model="${model//|/}"

  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$by_id" "$resolved" "$serial" "$vendor" "$model" "$size_b" "$size_h" "$usb"
}

# Enumerate all candidate removable (or loop) disks.
# Prints one metadata line per device.
enumerate_removable_drives() {
  local allow_loop="${1:-0}"
  local name typ rm
  while IFS= read -r line; do
    name="$(awk '{print $1}' <<<"$line")"
    rm="$(awk '{print $2}' <<<"$line")"
    typ="$(awk '{print $3}' <<<"$line")"
    [[ -z "$name" ]] && continue
    if [[ "$typ" == "loop" ]]; then
      [[ "$allow_loop" == "1" ]] || continue
      collect_device_metadata "/dev/$name" 1 || true
      continue
    fi
    if [[ "$typ" == "disk" && "$rm" == "1" ]]; then
      collect_device_metadata "/dev/$name" 0 || true
    fi
  done < <(lsblk -dpno NAME,RM,TYPE 2>/dev/null | sed 's|^/dev/||' | awk '{print $1,$2,$3}')
}

# Resolve user-supplied args into metadata lines (deduped by resolved path).
resolve_user_targets() {
  local allow_loop="${1:-0}"
  shift
  local seen="" meta resolved
  local arg
  for arg in "$@"; do
    meta="$(collect_device_metadata "$arg" "$allow_loop")" || continue
    resolved="$(cut -d'|' -f2 <<<"$meta")"
    if [[ " $seen " == *" $resolved "* ]]; then
      continue
    fi
    seen+=" $resolved"
    printf '%s\n' "$meta"
  done
}
