#!/usr/bin/env bash
# Safety gates: root, dependencies, mount/system exclusions, by-id pinning.

set -euo pipefail

FLASH_TEST_REQUIRED_CMDS=(
  lsblk findmnt udevadm realpath awk sed grep cut tr timeout
)

FLASH_TEST_FORMAT_CMDS=(wipefs parted)
FLASH_TEST_TEST_CMDS=(f3probe f3write f3read badblocks fio)

# ---------------------------------------------------------------------------
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "error: flash-test must run as root (destructive block I/O)." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
check_dependencies() {
  local missing=()
  local cmd
  for cmd in "${FLASH_TEST_REQUIRED_CMDS[@]}" "${FLASH_TEST_TEST_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [[ "${FLASH_TEST_FORMAT:-exfat}" != "none" ]]; then
    for cmd in "${FLASH_TEST_FORMAT_CMDS[@]}"; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
      fi
    done
    local has_fmt=0
    case "${FLASH_TEST_FORMAT:-exfat}" in
      exfat) command -v mkfs.exfat >/dev/null 2>&1 && has_fmt=1 ;;
      vfat|fat32) command -v mkfs.vfat >/dev/null 2>&1 && has_fmt=1 ;;
      ext4) command -v mkfs.ext4 >/dev/null 2>&1 && has_fmt=1 ;;
    esac
    if [[ $has_fmt -eq 0 ]]; then
      missing+=("mkfs.${FLASH_TEST_FORMAT:-exfat}")
    fi
  fi
  if ((${#missing[@]})); then
    echo "error: missing required commands: ${missing[*]}" >&2
    echo "hint: install util-linux, f3, e2fsprogs, fio, parted, and exfatprogs/dosfstools as needed." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Resolve bare /dev/sdX or /dev/loopN to a stable by-id (or by-path) symlink.
pin_device_by_id() {
  local dev="$1"
  local resolved
  resolved="$(realpath -e "$dev" 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    echo "error: device not found: $dev" >&2
    return 1
  fi

  local link candidate
  # Prefer USB/ata/scsi by-id links (skip partition -partN links)
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

  # Loop devices often lack by-id; use realpath as last resort when allowed
  if [[ "$resolved" == /dev/loop* ]]; then
    echo "$resolved"
    return 0
  fi

  echo "error: could not resolve by-id for $dev ($resolved)" >&2
  return 1
}

# ---------------------------------------------------------------------------
_parent_disk_of_source() {
  # Normalize findmnt SOURCE (/dev/sda2, /dev/mapper/..., UUID=...) to parent disk path
  local src="$1"
  local node
  if [[ "$src" == UUID=* ]] || [[ "$src" == PARTUUID=* ]] || [[ "$src" == LABEL=* ]]; then
    node="$(findfs "$src" 2>/dev/null || true)"
  else
    node="$src"
  fi
  [[ -z "$node" ]] && return 1
  node="$(realpath -e "$node" 2>/dev/null || true)"
  [[ -z "$node" ]] && return 1

  # If partition, ask lsblk for PKNAME
  local pk
  pk="$(lsblk -no PKNAME "$node" 2>/dev/null | head -n1 | tr -d '[:space:]')"
  if [[ -n "$pk" ]]; then
    echo "/dev/$pk"
    return 0
  fi
  # Whole disk or mapper without PKNAME
  local typ
  typ="$(lsblk -no TYPE "$node" 2>/dev/null | head -n1 | tr -d '[:space:]')"
  if [[ "$typ" == "disk" || "$typ" == "loop" ]]; then
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

# ---------------------------------------------------------------------------
device_has_any_mount() {
  local dev="$1"
  local mp
  while IFS= read -r mp; do
    [[ -z "$mp" ]] && continue
    return 0
  done < <(lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null)
  return 1
}

device_has_system_mount_or_swap() {
  local dev="$1"
  local line mp fstype
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

# ---------------------------------------------------------------------------
# Returns 0 if device is safe to target for testing.
# Args: device path, allow_loop (0|1)
validate_target_device() {
  local dev="$1"
  local allow_loop="${2:-0}"
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

  if [[ "$typ" != "disk" && "$typ" != "loop" ]]; then
    echo "skip: not a disk: $dev (type=$typ)" >&2
    return 1
  fi

  if [[ "$typ" == "loop" ]]; then
    if [[ "$allow_loop" != "1" ]]; then
      echo "skip: loop device requires --allow-loop: $dev" >&2
      return 1
    fi
  else
    if [[ "$rm" != "1" ]]; then
      echo "skip: not removable (RM!=1): $dev" >&2
      return 1
    fi
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

  # Destructive modes: any mount is unsafe until we unmount; for validation
  # at discovery we still allow listing mounted removable media but the
  # pipeline re-checks after umount. Here we flag system mounts only above.
  return 0
}

# Stricter pre-write check: no mounts at all.
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

  # Unmount partitions first (deepest mountpoints), then whole disk
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
║  Data on selected drives will be DESTROYED.                  ║
╚══════════════════════════════════════════════════════════════╝
EOF
}
