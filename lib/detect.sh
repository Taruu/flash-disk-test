#!/usr/bin/env bash
# Enumerate removable drives; one metadata line per stick.

set -euo pipefail

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

_udev_prop() {
  local dev="$1" key="$2"
  udevadm info --query=property --name="$dev" 2>/dev/null \
    | grep -E "^${key}=" | head -n1 | cut -d= -f2- || true
}

_usb_speed() {
  local dev="$1"
  local speed id_bus
  id_bus="$(_udev_prop "$dev" ID_BUS)"
  if [[ "$id_bus" != "usb" ]]; then
    echo "${id_bus:-unknown}"
    return 0
  fi
  speed="$(_udev_prop "$dev" ID_USB_SPEED)"
  if [[ -z "$speed" ]]; then
    local sys d
    sys="$(udevadm info -q path -n "$dev" 2>/dev/null || true)"
    if [[ -n "$sys" ]]; then
      d="/sys${sys}"
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

_device_uuid() {
  local resolved="$1" by_id="$2" serial="$3"
  local uuid
  uuid="$(_udev_prop "$resolved" ID_PART_TABLE_UUID)"
  if [[ -z "$uuid" ]]; then
    uuid="$(_udev_prop "$resolved" ID_FS_UUID)"
  fi
  if [[ -z "$uuid" ]]; then
    uuid="$serial"
  fi
  if [[ -z "$uuid" ]]; then
    uuid="$(basename "$by_id")"
  fi
  echo "$uuid"
}

# Fields: by_id|resolved|serial|vendor|model|size_bytes|size_human|usb_speed|uuid
collect_device_metadata() {
  local dev="$1"
  local by_id resolved serial vendor model size_b size_h usb uuid

  if ! validate_target_device "$dev"; then
    return 1
  fi

  by_id="$(pin_device_by_id "$dev")" || return 1
  resolved="$(realpath -e "$by_id")"
  serial="$(_udev_prop "$resolved" ID_SERIAL_SHORT)"
  [[ -z "$serial" ]] && serial="$(_udev_prop "$resolved" ID_SERIAL)"
  [[ -z "$serial" ]] && serial="$(basename "$by_id" | tr '/' '_')"

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
  uuid="$(_device_uuid "$resolved" "$by_id" "$serial")"

  serial="${serial//|/}"
  vendor="${vendor//|/}"
  model="${model//|/}"
  uuid="${uuid//|/}"

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$by_id" "$resolved" "$serial" "$vendor" "$model" "$size_b" "$size_h" "$usb" "$uuid"
}

enumerate_removable_drives() {
  local name typ rm
  while IFS= read -r line; do
    name="$(awk '{print $1}' <<<"$line")"
    rm="$(awk '{print $2}' <<<"$line")"
    typ="$(awk '{print $3}' <<<"$line")"
    [[ -z "$name" ]] && continue
    if [[ "$typ" == "disk" && "$rm" == "1" ]]; then
      collect_device_metadata "/dev/$name" || true
    fi
  done < <(lsblk -dpno NAME,RM,TYPE 2>/dev/null | sed 's|^/dev/||' | awk '{print $1,$2,$3}')
}

list_drives_human() {
  local line by_id resolved serial vendor model size_b size_h usb uuid
  local found=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    found=1
    IFS='|' read -r by_id resolved serial vendor model size_b size_h usb uuid <<<"$line"
    printf '%-12s  UUID=%-22s  %8s  %-5s  %s %s\n' \
      "$(basename "$resolved")" "$uuid" "$size_h" "$usb" "$vendor" "$model"
  done < <(enumerate_removable_drives)
  if [[ $found -eq 0 ]]; then
    echo "(no safe removable drives found)"
  fi
}
