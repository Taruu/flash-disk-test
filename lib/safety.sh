#!/usr/bin/env bash
# Safety gates: root, deps, removable-only, umount, system-disk guard.

set -euo pipefail

FLASH_TEST_REQUIRED_CMDS=(
  lsblk findmnt udevadm realpath awk sed grep cut tr timeout tee
  f3probe badblocks smartctl hdparm wipefs parted mkfs.exfat fsck.exfat
)

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "error: flash-test must run as root (destructive block I/O)." >&2
    exit 1
  fi
}

check_dependencies() {
  local missing=() cmd
  for cmd in "${FLASH_TEST_REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if ((${#missing[@]})); then
    echo "error: missing required commands: ${missing[*]}" >&2
    echo "hint: sudo apt install f3 e2fsprogs smartmontools hdparm parted exfatprogs util-linux" >&2
    exit 1
  fi
}

pin_device_by_id() {
  local dev="$1"
  local resolved link candidate
  resolved="$(realpath -e "$dev" 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    echo "error: device not found: $dev" >&2
    return 1
  fi

  shopt -s nullglob
  for link in /dev/disk/by-id/*; do
    [[ -e "$link" ]] || continue
    [[ "$link" == *-part* ]] && continue
    candidate="$(realpath -e "$link" 2>/dev/null || true)"
    if [[ "$candidate" == "$resolved" ]]; then
      echo "$link"
      shopt -u nullglob
      return 0
    fi
  done
  for link in /dev/disk/by-path/*; do
    [[ -e "$link" ]] || continue
    [[ "$link" == *-part* ]] && continue
    candidate="$(realpath -e "$link" 2>/dev/null || true)"
    if [[ "$candidate" == "$resolved" ]]; then
      echo "$link"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob

  echo "error: could not resolve by-id for $dev ($resolved)" >&2
  return 1
}

_parent_disk_of_source() {
  local src="$1"
  local node pk typ
  if [[ "$src" == UUID=* ]] || [[ "$src" == PARTUUID=* ]] || [[ "$src" == LABEL=* ]]; then
    node="$(findfs "$src" 2>/dev/null || true)"
  else
    node="$src"
  fi
  [[ -z "$node" ]] && return 1
  node="$(realpath -e "$node" 2>/dev/null || true)"
  [[ -z "$node" ]] && return 1

  pk="$(lsblk -no PKNAME "$node" 2>/dev/null | head -n1 | tr -d '[:space:]')"
  if [[ -n "$pk" ]]; then
    echo "/dev/$pk"
    return 0
  fi
  typ="$(lsblk -no TYPE "$node" 2>/dev/null | head -n1 | tr -d '[:space:]')"
  if [[ "$typ" == "disk" ]]; then
    echo "$node"
    return 0
  fi
  echo "$node"
}

root_backing_disk() {
  local src
  src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [[ -z "$src" ]] && return 1
  _parent_disk_of_source "$src"
}

device_has_any_mount() {
  local dev="$1" mp
  while IFS= read -r mp; do
    [[ -z "$mp" ]] && continue
    return 0
  done < <(lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null)
  return 1
}

device_has_system_mount_or_swap() {
  local dev="$1" line mp fstype
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    mp="$(awk '{print $1}' <<<"$line")"
    fstype="$(awk '{print $2}' <<<"$line")"
    if [[ "$fstype" == "swap" ]]; then
      return 0
    fi
    case "$mp" in
      /|/boot|/boot/*|/home|/home/*|/var|/var/*|/usr|/usr/*|/root|/root/*)
        return 0
        ;;
    esac
  done < <(lsblk -n -o MOUNTPOINT,FSTYPE "$dev" 2>/dev/null | awk 'NF')
  return 1
}

is_root_disk() {
  local dev="$1"
  local root_disk resolved
  root_disk="$(root_backing_disk 2>/dev/null || true)"
  [[ -z "$root_disk" ]] && return 1
  resolved="$(realpath -e "$dev" 2>/dev/null || true)"
  root_disk="$(realpath -e "$root_disk" 2>/dev/null || true)"
  [[ -n "$resolved" && "$resolved" == "$root_disk" ]]
}

validate_target_device() {
  local dev="$1"
  local resolved name rm ro typ

  resolved="$(realpath -e "$dev" 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    echo "skip: not found: $dev" >&2
    return 1
  fi

  name="$(basename "$resolved")"
  rm="$(lsblk -dn -o RM "/dev/$name" 2>/dev/null | tr -d '[:space:]')"
  ro="$(lsblk -dn -o RO "/dev/$name" 2>/dev/null | tr -d '[:space:]')"
  typ="$(lsblk -dn -o TYPE "/dev/$name" 2>/dev/null | tr -d '[:space:]')"

  if [[ "$typ" != "disk" ]]; then
    echo "skip: not a disk: $dev (type=$typ)" >&2
    return 1
  fi
  if [[ "$rm" != "1" ]]; then
    echo "skip: not removable (RM!=1): $dev" >&2
    return 1
  fi
  if [[ "$ro" == "1" ]]; then
    echo "skip: read-only: $dev" >&2
    return 1
  fi
  if is_root_disk "$resolved"; then
    echo "skip: refuses root-backing disk: $dev" >&2
    return 1
  fi
  if device_has_system_mount_or_swap "$resolved"; then
    echo "skip: system mount or swap on $dev" >&2
    return 1
  fi
  return 0
}

assert_unmounted() {
  local dev="$1"
  if device_has_any_mount "$dev"; then
    echo "error: device still has mountpoints: $dev" >&2
    lsblk -n -o NAME,MOUNTPOINT "$dev" >&2 || true
    return 1
  fi
  return 0
}

umount_device_tree() {
  local dev="$1"
  local resolved parts p
  resolved="$(realpath -e "$dev" 2>/dev/null || true)"
  [[ -z "$resolved" ]] && return 0

  mapfile -t parts < <(lsblk -ln -o NAME,TYPE "$resolved" | awk '$2=="part"{print "/dev/"$1}')
  for p in "${parts[@]:-}"; do
    [[ -z "$p" ]] && continue
    umount -R "$p" 2>/dev/null || umount "$p" 2>/dev/null || true
  done
  umount -R "$resolved" 2>/dev/null || umount "$resolved" 2>/dev/null || true
}

print_destructive_banner() {
  cat <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║  WARNING: DESTRUCTIVE FLASH TESTS                            ║
║  Data on the selected drive will be DESTROYED.               ║
╚══════════════════════════════════════════════════════════════╝
EOF
}
